# Business functies – syntax in SQL, Python en R

20 ArchiMate business functies. Per functie: SQL (DuckDB), SQL (Trino), Python (pandas) en R (tidyverse).

## Conventies

Alle voorbeelden gebruiken dezelfde (fictieve) tabellen. Pas namen en drempels aan naar de eigen data.

| Tabel / dataframe | Kolommen |
|---|---|
| `microdata` | `id`, `sbi`, `gemeente`, `leeftijd`, `beroep_tekst`, `omzet`, `kosten`, `winst`, `personeel`, `omzet_vorig`, `personeel_vorig`, `gewicht` |
| overige tabellen | worden bij de functie zelf beschreven |

- Python: `import pandas as pd, numpy as np`; dataframe heet `df` (= `microdata`).
- R: `library(dplyr); library(tidyr); library(stringr); library(purrr); library(tibble)`; data heet `microdata`.
- Waar DuckDB en Trino dezelfde syntax hebben staat één blok "DuckDB & Trino".
- Verschillen die ertoe doen: gehele deling (Trino deelt `bigint/bigint` als geheel getal, dus altijd `CAST(.. AS DOUBLE)`), regex (`regexp_matches` vs `regexp_like`), percentielen (`quantile_cont` vs `approx_percentile`), `median` (alleen DuckDB), `EXCLUDE`/`COLUMNS`/`UNION ALL BY NAME` (alleen DuckDB).
- Een ontbrekende waarde levert bij de controles hieronder `FALSE` (niet valide / niet plausibel). Haal de `COALESCE` weg als je `NULL` wilt houden.

---

## 1. Controleren validiteit

Controle van één variabele t.o.v. een vast bereik; resultaat is een indicator (true/false). Herhaal per variabele.

**SQL – DuckDB & Trino**
```sql
SELECT m.*,
       COALESCE(leeftijd BETWEEN 0 AND 120, FALSE)       AS leeftijd_valide,
       COALESCE(sbi IN ('47111', '47112', '56101'), FALSE) AS sbi_valide      -- codelijst
FROM microdata m;
```

**Python**
```python
df["leeftijd_valide"] = df["leeftijd"].between(0, 120)            # NaN -> False
df["sbi_valide"] = df["sbi"].isin(["47111", "47112", "56101"])
```

**R**
```r
microdata |>
  mutate(leeftijd_valide = !is.na(leeftijd) & between(leeftijd, 0, 120),
         sbi_valide      = sbi %in% c("47111", "47112", "56101"))
```

---

## 2. Afleiden variabelen (typeren)

Open tekst → categorie; alleen het waardenbereik verandert.

**SQL – DuckDB**
```sql
SELECT m.*,
       CASE WHEN beroep_tekst IS NULL THEN NULL
            WHEN regexp_matches(lower(beroep_tekst), 'verpleeg|arts|zorg')    THEN 'Zorg'
            WHEN regexp_matches(lower(beroep_tekst), 'leraar|docent|onderwijs') THEN 'Onderwijs'
            ELSE 'Overig' END AS beroepsgroep
FROM microdata m;
```

**SQL – Trino**
```sql
SELECT m.*,
       CASE WHEN beroep_tekst IS NULL THEN NULL
            WHEN regexp_like(lower(beroep_tekst), 'verpleeg|arts|zorg')    THEN 'Zorg'
            WHEN regexp_like(lower(beroep_tekst), 'leraar|docent|onderwijs') THEN 'Onderwijs'
            ELSE 'Overig' END AS beroepsgroep
FROM microdata m;
```

**Python**
```python
t = df["beroep_tekst"].str.lower()
df["beroepsgroep"] = np.select(
    [t.str.contains("verpleeg|arts|zorg", na=False),
     t.str.contains("leraar|docent|onderwijs", na=False)],
    ["Zorg", "Onderwijs"], default="Overig")
df.loc[t.isna(), "beroepsgroep"] = None
```

**R**
```r
microdata |>
  mutate(beroepsgroep = case_when(
    is.na(beroep_tekst)                                        ~ NA_character_,
    str_detect(str_to_lower(beroep_tekst), "verpleeg|arts|zorg")    ~ "Zorg",
    str_detect(str_to_lower(beroep_tekst), "leraar|docent|onderwijs") ~ "Onderwijs",
    TRUE                                                       ~ "Overig"))
```

> Voor de optionele "zachte" uitkomst (kansverdeling) is een classifier nodig (bijv. scikit-learn `predict_proba`, R `caret`/`tidymodels`); dat is niet in SQL te doen.

---

## 3. Afleiden variabelen (indikken)

Detailcodes → ingedikte codes via een codelijst `codelijst_indikking(code_detail, code_ingedikt)`.

**SQL – DuckDB & Trino**
```sql
SELECT m.*, k.code_ingedikt AS sbi_ingedikt
FROM microdata m
LEFT JOIN codelijst_indikking k ON m.sbi = k.code_detail;

-- variant bij een hiërarchische code: eerste 2 posities
SELECT m.*, substr(sbi, 1, 2) AS sbi_2 FROM microdata m;
```

**Python**
```python
df = df.merge(codelijst_indikking.rename(columns={"code_detail": "sbi", "code_ingedikt": "sbi_ingedikt"}),
              on="sbi", how="left")
# variant: df["sbi_2"] = df["sbi"].str[:2]
```

**R**
```r
microdata |>
  left_join(codelijst_indikking, by = c("sbi" = "code_detail")) |>
  rename(sbi_ingedikt = code_ingedikt)
# variant: mutate(sbi_2 = str_sub(sbi, 1, 2))
```

---

## 4. Controle op validiteit: algemene set controleregels

Regels over combinaties van variabelen, daarna foutlokalisatie (Fellegi-Holt). Voorbeeldregels:
`omzet = kosten + winst`, `omzet >= 0`, `kosten >= 0`, `personeel >= 0`.

**SQL – DuckDB & Trino** (regelcontrole + heuristische lokalisatie: per geschonden regel wordt de variabele aangemerkt die in de meeste geschonden regels voorkomt; exacte Fellegi-Holt kan niet in SQL, zie Python/R)
```sql
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
```

**Python** (exacte Fellegi-Holt voor lineaire regels: kleinste set variabelen die vrij gemaakt moet worden om alle regels te laten gelden; haalbaarheid via LP)
```python
import itertools
from scipy.optimize import linprog

variabelen = ["omzet", "kosten", "winst", "personeel"]
A_eq = np.array([[1, -1, -1, 0]]);  b_eq = np.array([0.0])               # omzet = kosten + winst
A_ub = np.array([[-1, 0, 0, 0], [0, -1, 0, 0], [0, 0, 0, -1]]); b_ub = np.zeros(3)  # omzet, kosten, personeel >= 0

def haalbaar(x, vrij):
    bounds = [(None, None) if i in vrij else (x[i], x[i]) for i in range(len(x))]
    res = linprog(np.zeros(len(x)), A_ub=A_ub, b_ub=b_ub, A_eq=A_eq, b_eq=b_eq,
                  bounds=bounds, method="highs")
    return res.status == 0

def lokaliseer(x):
    ontbrekend = {i for i in range(len(x)) if np.isnan(x[i])}      # ontbrekend = geen fout, wel vrij
    x0 = np.nan_to_num(x)
    if haalbaar(x0, ontbrekend):
        return set()
    waargenomen = [i for i in range(len(x)) if i not in ontbrekend]
    for k in range(1, len(waargenomen) + 1):                        # minimale cardinaliteit
        for S in itertools.combinations(waargenomen, k):
            if haalbaar(x0, ontbrekend | set(S)):
                return set(S)                                       # eerste minimale set

fouten = [lokaliseer(x) for x in df[variabelen].to_numpy(float)]
for j, v in enumerate(variabelen):
    df[f"{v}_valide"] = [j not in f for f in fouten]
# optioneel leegmaken: df.loc[~df["omzet_valide"], "omzet"] = np.nan
```

**R** (pakketten `validate` + `errorlocate`, Fellegi-Holt)
```r
library(validate); library(errorlocate)

regels <- validator(omzet == kosten + winst, omzet >= 0, kosten >= 0, personeel >= 0)
dat    <- as.data.frame(microdata[, c("omzet", "kosten", "winst", "personeel")])

fout   <- locate_errors(dat, regels)$errors          # logische matrix, TRUE = foutieve waarde
valide <- as_tibble(!fout) |> rename_with(~ paste0(.x, "_valide"))
resultaat <- bind_cols(microdata, valide)
# optioneel leegmaken: replace_errors(dat, regels)
```

---

## 5. Imputatie

Ratio-imputatie: ontbrekende `omzet` = `personeel` × (Σomzet / Σpersoneel) binnen de SBI-stratum van de responderende eenheden.

**SQL – DuckDB & Trino**
```sql
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
```

**Python**
```python
donor = df[df["omzet"].notna() & (df["personeel"] > 0)]
som = donor.groupby("sbi")[["omzet", "personeel"]].sum()
ratio = df["sbi"].map(som["omzet"] / som["personeel"])

df["omzet_is_geimputeerd"] = df["omzet"].isna() & (df["personeel"] * ratio).notna()
df["omzet_geimputeerd"] = df["omzet"].fillna(df["personeel"] * ratio)
```

**R**
```r
ratio <- microdata |>
  filter(!is.na(omzet), personeel > 0) |>
  group_by(sbi) |>
  summarise(omzet_per_pers = sum(omzet) / sum(personeel), .groups = "drop")

microdata |>
  left_join(ratio, by = "sbi") |>
  mutate(omzet_is_geimputeerd = is.na(omzet) & !is.na(personeel * omzet_per_pers),
         omzet_geimputeerd    = coalesce(omzet, personeel * omzet_per_pers))
```

> Andere methoden (hot-deck, regressie, PMM): Python `sklearn.impute` / `statsmodels`, R `VIM`, `mice`, `simputation`.

---

## 6. Afleiden variabelen algemeen

Nieuwe variabele(n) uit één of meer bestaande; hier één voorbeeld van elk soort (afleiden, omzetten meetschaal, indikken, typeren).

**SQL – DuckDB**
```sql
SELECT m.*,
       CAST(omzet AS DOUBLE) / NULLIF(personeel, 0)                                    AS omzet_per_werknemer,
       CASE WHEN personeel < 10 THEN 'klein' WHEN personeel < 100 THEN 'midden' ELSE 'groot' END AS grootteklasse,
       substr(sbi, 1, 2)                                                               AS sbi_2,
       regexp_matches(lower(beroep_tekst), 'zorg|arts')                                AS is_zorg
FROM microdata m;
```

**SQL – Trino**
```sql
SELECT m.*,
       CAST(omzet AS DOUBLE) / NULLIF(personeel, 0)                                    AS omzet_per_werknemer,
       CASE WHEN personeel < 10 THEN 'klein' WHEN personeel < 100 THEN 'midden' ELSE 'groot' END AS grootteklasse,
       substr(sbi, 1, 2)                                                               AS sbi_2,
       regexp_like(lower(beroep_tekst), 'zorg|arts')                                   AS is_zorg
FROM microdata m;
```

**Python**
```python
df = df.assign(
    omzet_per_werknemer=df["omzet"] / df["personeel"].where(df["personeel"] != 0),
    grootteklasse=pd.cut(df["personeel"], [-np.inf, 10, 100, np.inf], labels=["klein", "midden", "groot"], right=False),
    sbi_2=df["sbi"].str[:2],
    is_zorg=df["beroep_tekst"].str.lower().str.contains("zorg|arts", na=False),
)
```

**R**
```r
microdata |>
  mutate(omzet_per_werknemer = omzet / na_if(personeel, 0),
         grootteklasse = cut(personeel, c(-Inf, 10, 100, Inf), c("klein", "midden", "groot"), right = FALSE),
         sbi_2   = str_sub(sbi, 1, 2),
         is_zorg = str_detect(str_to_lower(beroep_tekst), "zorg|arts"))
```

---

## 7. Controle op invloed en verdachtheid

Lokale scores per eenheid per variabele = verdachtheid × invloed; globale score = gemiddelde over de variabelen. Vereenvoudigde Hidiroglou-Berthelot-variant op basis van de ratio met T-1:
- verdachtheid `s = |1 − med/r|` als `r < med`, anders `|r/med − 1|`, met `r = y / y_vorig` en `med` de mediaan van `r`;
- invloed = `gewicht · max(y, y_vorig) / Σ(gewicht · y_vorig)`.

**SQL – DuckDB**
```sql
WITH lang AS (
  SELECT id, gewicht, 'omzet' AS variabele, omzet AS y, omzet_vorig AS y_vorig FROM microdata
  UNION ALL
  SELECT id, gewicht, 'personeel', personeel, personeel_vorig FROM microdata
), ratio AS (
  SELECT *, CAST(y AS DOUBLE) / NULLIF(y_vorig, 0) AS r FROM lang
), agg AS (
  SELECT variabele,
         median(CASE WHEN r > 0 THEN r END) AS med_r,
         SUM(gewicht * y_vorig)             AS totaal_vorig
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
```

**SQL – Trino** (zelfde query; alleen de mediaan wijkt af)
```sql
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
```

**Python**
```python
def lokale_scores(df, variabelen, gewicht="gewicht"):
    uit = []
    for v in variabelen:
        y, y0 = df[v], df[f"{v}_vorig"]
        r = (y / y0.where(y0 != 0)).where(lambda s: s > 0)
        med = r.median()
        s = pd.Series(np.abs(np.where(r < med, 1 - med / r, r / med - 1)), index=df.index).where(r.notna())
        invloed = df[gewicht] * np.maximum(y, y0) / (df[gewicht] * y0).sum()
        uit.append(pd.DataFrame({"id": df["id"], "variabele": v, "verdachtheid": s,
                                 "invloed": invloed, "lokale_score": s * invloed}))
    out = pd.concat(uit, ignore_index=True)
    out["globale_score"] = out.groupby("id")["lokale_score"].transform("mean")
    return out

scores = lokale_scores(df, ["omzet", "personeel"])
```

**R**
```r
lokale_scores <- function(df, variabelen) {
  map_dfr(variabelen, function(v) {
    y  <- df[[v]];  y0 <- df[[paste0(v, "_vorig")]]
    r  <- y / ifelse(y0 == 0, NA, y0);  r[!is.na(r) & r <= 0] <- NA
    med <- median(r, na.rm = TRUE)
    s  <- abs(ifelse(r < med, 1 - med / r, r / med - 1))
    invloed <- df$gewicht * pmax(y, y0) / sum(df$gewicht * y0, na.rm = TRUE)
    tibble(id = df$id, variabele = v, verdachtheid = s, invloed = invloed, lokale_score = s * invloed)
  }) |>
    group_by(id) |>
    mutate(globale_score = mean(lokale_score, na.rm = TRUE)) |>
    ungroup()
}
scores <- lokale_scores(microdata, c("omzet", "personeel"))
```

---

## 8. Afleiden variabelen (omzetten meetschaal)

Ratio-schaal → ordinale categorieën via drempelwaarden (hier 100.000 en 1.000.000).

**SQL – DuckDB & Trino**
```sql
SELECT m.*,
       CASE WHEN omzet IS NULL     THEN NULL
            WHEN omzet < 100000    THEN '1: klein'
            WHEN omzet < 1000000   THEN '2: midden'
            ELSE                        '3: groot' END AS omzetklasse
FROM microdata m;
```

**Python**
```python
df["omzetklasse"] = pd.cut(df["omzet"], bins=[-np.inf, 1e5, 1e6, np.inf],
                           labels=["1: klein", "2: midden", "3: groot"], right=False, ordered=True)
```

**R**
```r
microdata |>
  mutate(omzetklasse = cut(omzet, breaks = c(-Inf, 1e5, 1e6, Inf),
                           labels = c("1: klein", "2: midden", "3: groot"),
                           right = FALSE, ordered_result = TRUE))
```

---

## 9. Wegen / ophogen

Post-stratificatie: gewicht = populatieaantal / steekproefaantal per stratum. Populatietabel `populatie(sbi, n_pop)`.

**SQL – DuckDB & Trino**
```sql
WITH steekproef AS (
  SELECT sbi, COUNT(*) AS n_steekproef FROM microdata GROUP BY sbi
)
SELECT m.*, CAST(p.n_pop AS DOUBLE) / s.n_steekproef AS gewicht_nieuw
FROM microdata m
JOIN steekproef s ON m.sbi = s.sbi
JOIN populatie  p ON m.sbi = p.sbi;
```

**Python**
```python
n_steekproef = df.groupby("sbi")["id"].transform("count")
n_pop = df["sbi"].map(populatie.set_index("sbi")["n_pop"])
df["gewicht_nieuw"] = n_pop / n_steekproef
```

**R**
```r
microdata |>
  add_count(sbi, name = "n_steekproef") |>
  left_join(populatie, by = "sbi") |>
  mutate(gewicht_nieuw = n_pop / n_steekproef)
# meerdere hulpvariabelen/calibratie: survey::postStratify(), survey::calibrate(), sampling::calib()
```

---

## 10. Aggregatie

Micro → dimensionele dataset: eenheden classificeren naar dimensies (`sbi`, `gemeente`) en measures (gewogen) optellen.

**SQL – DuckDB & Trino**
```sql
SELECT sbi, gemeente,
       COUNT(*)              AS aantal_eenheden,
       SUM(gewicht)          AS aantal_geschat,
       SUM(gewicht * omzet)  AS omzet_gewogen,
       SUM(omzet)            AS omzet_ongewogen
FROM microdata
GROUP BY sbi, gemeente;
```

**Python**
```python
agg = (df.assign(omzet_gew=df["omzet"] * df["gewicht"])
         .groupby(["sbi", "gemeente"], as_index=False)
         .agg(aantal_eenheden=("id", "count"), aantal_geschat=("gewicht", "sum"),
              omzet_gewogen=("omzet_gew", "sum"), omzet_ongewogen=("omzet", "sum")))
```

**R**
```r
agg <- microdata |>
  group_by(sbi, gemeente) |>
  summarise(aantal_eenheden = n(), aantal_geschat = sum(gewicht),
            omzet_gewogen = sum(gewicht * omzet, na.rm = TRUE),
            omzet_ongewogen = sum(omzet, na.rm = TRUE), .groups = "drop")
```

> Kwaliteitsmetadata: aggregeer een indicator, bijv. `AVG(CASE WHEN omzet_valide THEN 1.0 ELSE 0.0 END)` (SQL), `.mean()` (pandas) of `mean(omzet_valide)` (R).

---

## 11. Inpassen (Stone)

Wijzig waarden zodat lineaire constraints `A·x = b` gelden: `x' = x + V Aᵀ (A V Aᵀ)⁻¹ (b − A x)`, met `V = diag(x)` (variantie evenredig met grootte). Voorbeeld: `loon + inkoop + overig = totaal` met tabel `kosten_detail(id, loon, inkoop, overig, totaal)`.

**SQL – DuckDB & Trino** (alleen één somconstraint; dan is de Stone-oplossing met `V = diag(x)` een proportionele schaling. Meerdere constraints → Python/R)
```sql
SELECT id,
       loon   * totaal / (loon + inkoop + overig) AS loon_ingepast,
       inkoop * totaal / (loon + inkoop + overig) AS inkoop_ingepast,
       overig * totaal / (loon + inkoop + overig) AS overig_ingepast,
       totaal
FROM kosten_detail
WHERE loon + inkoop + overig <> 0;
```
Let op: kolommen moeten `DOUBLE`/`DECIMAL` zijn (bij gehele getallen in Trino volgt gehele deling).

**Python** (algemeen, willekeurig aantal constraints)
```python
def stone(x, A, b, V=None):
    x = np.asarray(x, float)
    V = np.diag(x) if V is None else V
    return x + V @ A.T @ np.linalg.solve(A @ V @ A.T, np.asarray(b, float) - A @ x)

A = np.array([[1.0, 1.0, 1.0]])                                   # loon + inkoop + overig
rij = df[["loon", "inkoop", "overig", "totaal"]].to_numpy(float)
df[["loon_ingepast", "inkoop_ingepast", "overig_ingepast"]] = [stone(r[:3], A, [r[3]]) for r in rij]
```

**R**
```r
stone <- function(x, A, b, V = diag(x, nrow = length(x))) {
  x + V %*% t(A) %*% solve(A %*% V %*% t(A), b - A %*% x)
}
A <- matrix(1, nrow = 1, ncol = 3)
ingepast <- t(apply(kosten_detail[, c("loon", "inkoop", "overig", "totaal")], 1,
                    function(r) as.numeric(stone(r[1:3], A, r[4]))))
kosten_detail[, c("loon_ingepast", "inkoop_ingepast", "overig_ingepast")] <- ingepast
```

---

## 12. Controle op plausibiliteit

Waarde t.o.v. een berekend bereik: hier de IQR-grenzen (Q1 − 1,5·IQR, Q3 + 1,5·IQR) per SBI.

**SQL – DuckDB**
```sql
WITH grenzen AS (
  SELECT sbi,
         quantile_cont(omzet, 0.25) AS q1,
         quantile_cont(omzet, 0.75) AS q3
  FROM microdata GROUP BY sbi
)
SELECT m.*,
       COALESCE(m.omzet BETWEEN g.q1 - 1.5 * (g.q3 - g.q1)
                            AND g.q3 + 1.5 * (g.q3 - g.q1), FALSE) AS omzet_plausibel
FROM microdata m
LEFT JOIN grenzen g ON m.sbi = g.sbi;
```

**SQL – Trino**
```sql
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
```

**Python**
```python
q1 = df.groupby("sbi")["omzet"].transform(lambda s: s.quantile(0.25))
q3 = df.groupby("sbi")["omzet"].transform(lambda s: s.quantile(0.75))
iqr = q3 - q1
df["omzet_plausibel"] = df["omzet"].between(q1 - 1.5 * iqr, q3 + 1.5 * iqr)
```

**R**
```r
microdata |>
  group_by(sbi) |>
  mutate(q1 = quantile(omzet, 0.25, na.rm = TRUE), q3 = quantile(omzet, 0.75, na.rm = TRUE),
         omzet_plausibel = !is.na(omzet) & between(omzet, q1 - 1.5 * (q3 - q1), q3 + 1.5 * (q3 - q1))) |>
  ungroup() |>
  select(-q1, -q3)
```

---

## 13. Afleiden variabelen en eenheden

Nieuw objecttype: van personen naar huishoudens. Tabel `personen(persoon_id, huishouden_id, leeftijd, inkomen)` → één rij per huishouden.

**SQL – DuckDB & Trino**
```sql
SELECT huishouden_id,
       COUNT(*)                                        AS aantal_personen,
       AVG(leeftijd)                                   AS gem_leeftijd,
       MAX(leeftijd)                                   AS leeftijd_oudste,
       SUM(CASE WHEN leeftijd < 18 THEN 1 ELSE 0 END)  AS aantal_kinderen,
       SUM(inkomen)                                    AS huishoudinkomen
FROM personen
GROUP BY huishouden_id;
```

**Python**
```python
huishoudens = (personen.assign(kind=personen["leeftijd"] < 18)
               .groupby("huishouden_id", as_index=False)
               .agg(aantal_personen=("persoon_id", "count"), gem_leeftijd=("leeftijd", "mean"),
                    leeftijd_oudste=("leeftijd", "max"), aantal_kinderen=("kind", "sum"),
                    huishoudinkomen=("inkomen", "sum")))
```

**R**
```r
huishoudens <- personen |>
  group_by(huishouden_id) |>
  summarise(aantal_personen = n(), gem_leeftijd = mean(leeftijd), leeftijd_oudste = max(leeftijd),
            aantal_kinderen = sum(leeftijd < 18), huishoudinkomen = sum(inkomen), .groups = "drop")
```

---

## 14. Afleiden variabelen

Nieuwe eigenschap met eigen waardenbereik, zelfde objecttype (hier winstmarge en omzetgroei).

**SQL – DuckDB & Trino**
```sql
SELECT m.*,
       CAST(winst AS DOUBLE) / NULLIF(omzet, 0)                      AS winstmarge,
       CAST(omzet - omzet_vorig AS DOUBLE) / NULLIF(omzet_vorig, 0)  AS omzetgroei
FROM microdata m;
```

**Python**
```python
df["winstmarge"] = df["winst"] / df["omzet"].where(df["omzet"] != 0)
df["omzetgroei"] = (df["omzet"] - df["omzet_vorig"]) / df["omzet_vorig"].where(df["omzet_vorig"] != 0)
```

**R**
```r
microdata |>
  mutate(winstmarge = winst / na_if(omzet, 0),
         omzetgroei = (omzet - omzet_vorig) / na_if(omzet_vorig, 0))
```

---

## 15. Koppelen op foreign key

`bedrijven(bedrijf_id, naam, gemeente_code)` heeft een foreign key naar `gemeenten(gemeente_code, gemeente_naam, provincie)`. Dataset 1 blijft leidend; rijen uit dataset 2 worden herhaald bij dubbele sleutelwaarden.

**SQL – DuckDB & Trino**
```sql
SELECT b.*, g.gemeente_naam, g.provincie
FROM bedrijven b
LEFT JOIN gemeenten g ON b.gemeente_code = g.gemeente_code;
```

**Python**
```python
resultaat = bedrijven.merge(gemeenten, on="gemeente_code", how="left", validate="m:1")
```

**R**
```r
resultaat <- bedrijven |>
  left_join(gemeenten, by = "gemeente_code", relationship = "many-to-one")
```

---

## 16. Koppelen op primaire sleutel

`dataset1(id, omzet)` en `dataset2(id, personeel)`, beide uniek op `id`. Kies de jointype: left, right, inner of full outer.

**SQL – DuckDB & Trino**
```sql
SELECT COALESCE(d1.id, d2.id) AS id, d1.omzet, d2.personeel
FROM dataset1 d1
LEFT JOIN dataset2 d2 ON d1.id = d2.id;      -- RIGHT JOIN / INNER JOIN / FULL OUTER JOIN
```

**Python**
```python
resultaat = d1.merge(d2, on="id", how="left", validate="1:1")   # "right" | "inner" | "outer"
```

**R**
```r
resultaat <- left_join(d1, d2, by = "id", relationship = "one-to-one")
# right_join() | inner_join() | full_join()
```

---

## 17. Selectie van variabelen

**SQL – DuckDB**
```sql
SELECT id, sbi, omzet FROM microdata;

-- DuckDB-extra's
SELECT * EXCLUDE (beroep_tekst, gewicht) FROM microdata;   -- alles behalve ...
SELECT id, COLUMNS('^omzet') FROM microdata;               -- op patroon
```

**SQL – Trino**
```sql
SELECT id, sbi, omzet FROM microdata;
```

**Python**
```python
selectie = df[["id", "sbi", "omzet"]]
# alles behalve: df.drop(columns=["beroep_tekst", "gewicht"])
```

**R**
```r
selectie <- microdata |> select(id, sbi, omzet)
# alles behalve: select(-beroep_tekst, -gewicht)
```

---

## 18. Omcoderen

Codes van een variabele vervangen via een sleutel `koppelsleutel(code_oud, code_nieuw)`. Verrinnen = BSN → CBS-RIN; verprinnen = CBS-RIN → project-RIN. Voorbeeld: `persoon_data(bsn, leeftijd, inkomen)` en sleutel `bsn_rin(bsn, rin)`.

**SQL – DuckDB**
```sql
-- omcoderen/verrinnen: identificerende kolom vervangen, overige kolommen blijven
SELECT k.rin, p.* EXCLUDE (bsn)
FROM persoon_data p
LEFT JOIN bsn_rin k ON p.bsn = k.bsn;

-- verprinnen: projectgebonden RIN's aanmaken (bewaar de sleutel apart)
CREATE TABLE rin_project AS
SELECT rin, ROW_NUMBER() OVER (ORDER BY random()) AS project_rin
FROM (SELECT DISTINCT rin FROM bsn_rin);
```

**SQL – Trino**
```sql
SELECT k.rin, p.leeftijd, p.inkomen            -- kolommen expliciet (geen EXCLUDE in Trino)
FROM persoon_data p
LEFT JOIN bsn_rin k ON p.bsn = k.bsn;

CREATE TABLE rin_project AS
SELECT rin, ROW_NUMBER() OVER (ORDER BY random()) AS project_rin
FROM (SELECT DISTINCT rin FROM bsn_rin);
```

**Python**
```python
omgecodeerd = (persoon_data.merge(bsn_rin, on="bsn", how="left")
                           .drop(columns="bsn"))

rng = np.random.default_rng()                                   # verprinnen
rin_project = pd.DataFrame({"rin": bsn_rin["rin"].unique()})
rin_project["project_rin"] = rng.permutation(len(rin_project)) + 1
```

**R**
```r
omgecodeerd <- persoon_data |>
  left_join(bsn_rin, by = "bsn") |>
  select(-bsn)

rin_project <- tibble(rin = unique(bsn_rin$rin)) |>             # verprinnen
  mutate(project_rin = sample(n()))
```

---

## 19. Selectie van eenheden

Rijen selecteren op afbakeningen van waardenbereiken; kolommen blijven gelijk.

**SQL – DuckDB & Trino**
```sql
SELECT *
FROM microdata
WHERE sbi LIKE '47%'
  AND omzet >= 100000
  AND gemeente IN ('0363', '0599');
```

**Python**
```python
selectie = df[df["sbi"].str.startswith("47") & (df["omzet"] >= 100_000) & df["gemeente"].isin(["0363", "0599"])]
```

**R**
```r
selectie <- microdata |>
  filter(str_starts(sbi, "47"), omzet >= 100000, gemeente %in% c("0363", "0599"))
```

---

## 20. Samenvoegen (complementeren)

Rijen van twee datasets met identieke kolommen onder elkaar zetten.

**SQL – DuckDB**
```sql
SELECT * FROM dataset_a
UNION ALL BY NAME
SELECT * FROM dataset_b;
-- zonder dubbele rijen: UNION BY NAME
```

**SQL – Trino**
```sql
SELECT id, omzet, personeel FROM dataset_a     -- kolomvolgorde en -types moeten gelijk zijn
UNION ALL
SELECT id, omzet, personeel FROM dataset_b;
-- zonder dubbele rijen: UNION
```

**Python**
```python
samen = pd.concat([dataset_a, dataset_b], ignore_index=True)
# zonder dubbelen: .drop_duplicates()
```

**R**
```r
samen <- bind_rows(dataset_a, dataset_b)
# zonder dubbelen: distinct()
```
