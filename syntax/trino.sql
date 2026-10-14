-- Business functies – Trino

-- ======================================================================
-- 1. Controleren validiteit
-- ======================================================================
SELECT m.*,
       COALESCE(leeftijd BETWEEN 0 AND 120, FALSE)       AS leeftijd_valide,
       COALESCE(sbi IN ('47111', '47112', '56101'), FALSE) AS sbi_valide      -- codelijst
FROM microdata m;

-- ======================================================================
-- 2. Afleiden variabelen (typeren)
-- ======================================================================
SELECT m.*,
       CASE WHEN beroep_tekst IS NULL THEN NULL
            WHEN regexp_like(lower(beroep_tekst), 'verpleeg|arts|zorg')    THEN 'Zorg'
            WHEN regexp_like(lower(beroep_tekst), 'leraar|docent|onderwijs') THEN 'Onderwijs'
            ELSE 'Overig' END AS beroepsgroep
FROM microdata m;

-- ======================================================================
-- 3. Afleiden variabelen (indikken)
-- ======================================================================
SELECT m.*, k.code_ingedikt AS sbi_ingedikt
FROM microdata m
LEFT JOIN codelijst_indikking k ON m.sbi = k.code_detail;

-- variant bij een hiërarchische code: eerste 2 posities
SELECT m.*, substr(sbi, 1, 2) AS sbi_2 FROM microdata m;

-- ======================================================================
-- 4. Controle op validiteit: algemene set controleregels
-- ======================================================================
WITH regels AS (
  SELECT id, omzet, kosten, winst, personeel,
         COALESCE(ABS(omzet - (kosten + winst)) > 0.5, FALSE) AS r1,
         COALESCE(omzet     < 0, FALSE) AS r2,
         COALESCE(kosten    < 0, FALSE) AS r3,
         COALESCE(personeel < 0, FALSE) AS r4
  FROM microdata
), telling AS (
  SELECT *,
         CAST(r1 AS INTEGER) + CAST(r2 AS INTEGER) AS n_omzet,
         CAST(r1 AS INTEGER) + CAST(r3 AS INTEGER) AS n_kosten,
         CAST(r1 AS INTEGER)                       AS n_winst
  FROM regels
), fout AS (
  SELECT *,
         (r1 AND n_omzet  = GREATEST(n_omzet, n_kosten, n_winst)) OR r2 AS f_omzet,
         (r1 AND n_kosten = GREATEST(n_omzet, n_kosten, n_winst)) OR r3 AS f_kosten,
         (r1 AND n_winst  = GREATEST(n_omzet, n_kosten, n_winst))       AS f_winst,
         r4                                                             AS f_personeel
  FROM telling
)
SELECT id,
       NOT f_omzet     AS omzet_valide,
       NOT f_kosten    AS kosten_valide,
       NOT f_winst     AS winst_valide,
       NOT f_personeel AS personeel_valide
FROM fout;

-- ======================================================================
-- 5. Imputatie
-- ======================================================================
WITH verhouding AS (
  SELECT sbi, CAST(SUM(omzet) AS DOUBLE) / SUM(personeel) AS omzet_per_pers
  FROM microdata
  WHERE omzet IS NOT NULL AND personeel > 0
  GROUP BY sbi
)
SELECT m.*,
       COALESCE(m.omzet, m.personeel * v.omzet_per_pers)                          AS omzet_geimputeerd,
       (m.omzet IS NULL AND m.personeel * v.omzet_per_pers IS NOT NULL)           AS omzet_is_geimputeerd
FROM microdata m
LEFT JOIN verhouding v ON m.sbi = v.sbi;

-- ======================================================================
-- 6. Afleiden variabelen algemeen
-- ======================================================================
SELECT m.*,
       CAST(omzet AS DOUBLE) / NULLIF(personeel, 0)                                    AS omzet_per_werknemer,
       CASE WHEN personeel < 10 THEN 'klein' WHEN personeel < 100 THEN 'midden' ELSE 'groot' END AS grootteklasse,
       substr(sbi, 1, 2)                                                               AS sbi_2,
       regexp_like(lower(beroep_tekst), 'zorg|arts')                                   AS is_zorg
FROM microdata m;

-- ======================================================================
-- 7. Controle op invloed en verdachtheid
-- ======================================================================
WITH lang AS (
  SELECT id, gewicht, 'omzet' AS variabele, omzet AS y, omzet_vorig AS y_vorig FROM microdata
  UNION ALL
  SELECT id, gewicht, 'personeel', personeel, personeel_vorig FROM microdata
), ratio AS (
  SELECT *, CAST(y AS DOUBLE) / NULLIF(y_vorig, 0) AS r FROM lang
), agg AS (
  SELECT variabele,
         approx_percentile(CASE WHEN r > 0 THEN r END, 0.5) AS med_r,   -- <- verschil met DuckDB
         SUM(gewicht * y_vorig)                             AS totaal_vorig
  FROM ratio GROUP BY variabele
), score AS (
  SELECT r.id, r.variabele,
         CASE WHEN r.r IS NULL OR r.r <= 0 THEN NULL
              WHEN r.r < a.med_r THEN ABS(1 - a.med_r / r.r)
              ELSE ABS(r.r / a.med_r - 1) END                         AS verdachtheid,
         r.gewicht * GREATEST(r.y, r.y_vorig) / a.totaal_vorig        AS invloed
  FROM ratio r JOIN agg a ON r.variabele = a.variabele
)
SELECT id, variabele, verdachtheid, invloed,
       verdachtheid * invloed                                 AS lokale_score,
       AVG(verdachtheid * invloed) OVER (PARTITION BY id)     AS globale_score
FROM score
ORDER BY globale_score DESC;

-- ======================================================================
-- 8. Afleiden variabelen (omzetten meetschaal)
-- ======================================================================
SELECT m.*,
       CASE WHEN omzet IS NULL     THEN NULL
            WHEN omzet < 100000    THEN '1: klein'
            WHEN omzet < 1000000   THEN '2: midden'
            ELSE                        '3: groot' END AS omzetklasse
FROM microdata m;

-- ======================================================================
-- 9. Wegen / ophogen
-- ======================================================================
WITH steekproef AS (
  SELECT sbi, COUNT(*) AS n_steekproef FROM microdata GROUP BY sbi
)
SELECT m.*, CAST(p.n_pop AS DOUBLE) / s.n_steekproef AS gewicht_nieuw
FROM microdata m
JOIN steekproef s ON m.sbi = s.sbi
JOIN populatie  p ON m.sbi = p.sbi;

-- ======================================================================
-- 10. Aggregatie
-- ======================================================================
SELECT sbi, gemeente,
       COUNT(*)              AS aantal_eenheden,
       SUM(gewicht)          AS aantal_geschat,
       SUM(gewicht * omzet)  AS omzet_gewogen,
       SUM(omzet)            AS omzet_ongewogen
FROM microdata
GROUP BY sbi, gemeente;

-- ======================================================================
-- 11. Inpassen (Stone)
-- ======================================================================
SELECT id,
       loon   * totaal / (loon + inkoop + overig) AS loon_ingepast,
       inkoop * totaal / (loon + inkoop + overig) AS inkoop_ingepast,
       overig * totaal / (loon + inkoop + overig) AS overig_ingepast,
       totaal
FROM kosten_detail
WHERE loon + inkoop + overig <> 0;

-- ======================================================================
-- 12. Controle op plausibiliteit
-- ======================================================================
WITH grenzen AS (
  SELECT sbi,
         approx_percentile(omzet, 0.25) AS q1,
         approx_percentile(omzet, 0.75) AS q3
  FROM microdata GROUP BY sbi
)
SELECT m.*,
       COALESCE(m.omzet BETWEEN g.q1 - 1.5 * (g.q3 - g.q1)
                            AND g.q3 + 1.5 * (g.q3 - g.q1), FALSE) AS omzet_plausibel
FROM microdata m
LEFT JOIN grenzen g ON m.sbi = g.sbi;

-- ======================================================================
-- 13. Afleiden variabelen en eenheden
-- ======================================================================
SELECT huishouden_id,
       COUNT(*)                                        AS aantal_personen,
       AVG(leeftijd)                                   AS gem_leeftijd,
       MAX(leeftijd)                                   AS leeftijd_oudste,
       SUM(CASE WHEN leeftijd < 18 THEN 1 ELSE 0 END)  AS aantal_kinderen,
       SUM(inkomen)                                    AS huishoudinkomen
FROM personen
GROUP BY huishouden_id;

-- ======================================================================
-- 14. Afleiden variabelen
-- ======================================================================
SELECT m.*,
       CAST(winst AS DOUBLE) / NULLIF(omzet, 0)                      AS winstmarge,
       CAST(omzet - omzet_vorig AS DOUBLE) / NULLIF(omzet_vorig, 0)  AS omzetgroei
FROM microdata m;

-- ======================================================================
-- 15. Koppelen op foreign key
-- ======================================================================
SELECT b.*, g.gemeente_naam, g.provincie
FROM bedrijven b
LEFT JOIN gemeenten g ON b.gemeente_code = g.gemeente_code;

-- ======================================================================
-- 16. Koppelen op primaire sleutel
-- ======================================================================
SELECT COALESCE(d1.id, d2.id) AS id, d1.omzet, d2.personeel
FROM dataset1 d1
LEFT JOIN dataset2 d2 ON d1.id = d2.id;      -- RIGHT JOIN / INNER JOIN / FULL OUTER JOIN

-- ======================================================================
-- 17. Selectie van variabelen
-- ======================================================================
SELECT id, sbi, omzet FROM microdata;

-- ======================================================================
-- 18. Omcoderen
-- ======================================================================
SELECT k.rin, p.leeftijd, p.inkomen            -- kolommen expliciet (geen EXCLUDE in Trino)
FROM persoon_data p
LEFT JOIN bsn_rin k ON p.bsn = k.bsn;

CREATE TABLE rin_project AS
SELECT rin, ROW_NUMBER() OVER (ORDER BY random()) AS project_rin
FROM (SELECT DISTINCT rin FROM bsn_rin);

-- ======================================================================
-- 19. Selectie van eenheden
-- ======================================================================
SELECT *
FROM microdata
WHERE sbi LIKE '47%'
  AND omzet >= 100000
  AND gemeente IN ('0363', '0599');

-- ======================================================================
-- 20. Samenvoegen (complementeren)
-- ======================================================================
SELECT id, omzet, personeel FROM dataset_a     -- kolomvolgorde en -types moeten gelijk zijn
UNION ALL
SELECT id, omzet, personeel FROM dataset_b;
-- zonder dubbele rijen: UNION
