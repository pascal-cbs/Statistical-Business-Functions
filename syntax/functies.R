# Business functies – R (tidyverse). Verwacht data frame `microdata` en overige tabellen.
library(dplyr); library(tidyr); library(stringr); library(purrr); library(tibble)

# ======================================================================
# 1. Controleren validiteit
# ======================================================================
microdata |>
  mutate(leeftijd_valide = !is.na(leeftijd) & between(leeftijd, 0, 120),
         sbi_valide      = sbi %in% c("47111", "47112", "56101"))

# ======================================================================
# 2. Afleiden variabelen (typeren)
# ======================================================================
microdata |>
  mutate(beroepsgroep = case_when(
    is.na(beroep_tekst)                                        ~ NA_character_,
    str_detect(str_to_lower(beroep_tekst), "verpleeg|arts|zorg")    ~ "Zorg",
    str_detect(str_to_lower(beroep_tekst), "leraar|docent|onderwijs") ~ "Onderwijs",
    TRUE                                                       ~ "Overig"))

# ======================================================================
# 3. Afleiden variabelen (indikken)
# ======================================================================
microdata |>
  left_join(codelijst_indikking, by = c("sbi" = "code_detail")) |>
  rename(sbi_ingedikt = code_ingedikt)
# variant: mutate(sbi_2 = str_sub(sbi, 1, 2))

# ======================================================================
# 4. Controle op validiteit: algemene set controleregels
# ======================================================================
library(validate); library(errorlocate)

regels <- validator(omzet == kosten + winst, omzet >= 0, kosten >= 0, personeel >= 0)
dat    <- as.data.frame(microdata[, c("omzet", "kosten", "winst", "personeel")])

fout   <- locate_errors(dat, regels)$errors          # logische matrix, TRUE = foutieve waarde
valide <- as_tibble(!fout) |> rename_with(~ paste0(.x, "_valide"))
resultaat <- bind_cols(microdata, valide)
# optioneel leegmaken: replace_errors(dat, regels)

# ======================================================================
# 5. Imputatie
# ======================================================================
ratio <- microdata |>
  filter(!is.na(omzet), personeel > 0) |>
  group_by(sbi) |>
  summarise(omzet_per_pers = sum(omzet) / sum(personeel), .groups = "drop")

microdata |>
  left_join(ratio, by = "sbi") |>
  mutate(omzet_is_geimputeerd = is.na(omzet) & !is.na(personeel * omzet_per_pers),
         omzet_geimputeerd    = coalesce(omzet, personeel * omzet_per_pers))

# ======================================================================
# 6. Afleiden variabelen algemeen
# ======================================================================
microdata |>
  mutate(omzet_per_werknemer = omzet / na_if(personeel, 0),
         grootteklasse = cut(personeel, c(-Inf, 10, 100, Inf), c("klein", "midden", "groot"), right = FALSE),
         sbi_2   = str_sub(sbi, 1, 2),
         is_zorg = str_detect(str_to_lower(beroep_tekst), "zorg|arts"))

# ======================================================================
# 7. Controle op invloed en verdachtheid
# ======================================================================
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

# ======================================================================
# 8. Afleiden variabelen (omzetten meetschaal)
# ======================================================================
microdata |>
  mutate(omzetklasse = cut(omzet, breaks = c(-Inf, 1e5, 1e6, Inf),
                           labels = c("1: klein", "2: midden", "3: groot"),
                           right = FALSE, ordered_result = TRUE))

# ======================================================================
# 9. Wegen / ophogen
# ======================================================================
microdata |>
  add_count(sbi, name = "n_steekproef") |>
  left_join(populatie, by = "sbi") |>
  mutate(gewicht_nieuw = n_pop / n_steekproef)
# meerdere hulpvariabelen/calibratie: survey::postStratify(), survey::calibrate(), sampling::calib()

# ======================================================================
# 10. Aggregatie
# ======================================================================
agg <- microdata |>
  group_by(sbi, gemeente) |>
  summarise(aantal_eenheden = n(), aantal_geschat = sum(gewicht),
            omzet_gewogen = sum(gewicht * omzet, na.rm = TRUE),
            omzet_ongewogen = sum(omzet, na.rm = TRUE), .groups = "drop")

# ======================================================================
# 11. Inpassen (Stone)
# ======================================================================
stone <- function(x, A, b, V = diag(x, nrow = length(x))) {
  x + V %*% t(A) %*% solve(A %*% V %*% t(A), b - A %*% x)
}
A <- matrix(1, nrow = 1, ncol = 3)
ingepast <- t(apply(kosten_detail[, c("loon", "inkoop", "overig", "totaal")], 1,
                    function(r) as.numeric(stone(r[1:3], A, r[4]))))
kosten_detail[, c("loon_ingepast", "inkoop_ingepast", "overig_ingepast")] <- ingepast

# ======================================================================
# 12. Controle op plausibiliteit
# ======================================================================
microdata |>
  group_by(sbi) |>
  mutate(q1 = quantile(omzet, 0.25, na.rm = TRUE), q3 = quantile(omzet, 0.75, na.rm = TRUE),
         omzet_plausibel = !is.na(omzet) & between(omzet, q1 - 1.5 * (q3 - q1), q3 + 1.5 * (q3 - q1))) |>
  ungroup() |>
  select(-q1, -q3)

# ======================================================================
# 13. Afleiden variabelen en eenheden
# ======================================================================
huishoudens <- personen |>
  group_by(huishouden_id) |>
  summarise(aantal_personen = n(), gem_leeftijd = mean(leeftijd), leeftijd_oudste = max(leeftijd),
            aantal_kinderen = sum(leeftijd < 18), huishoudinkomen = sum(inkomen), .groups = "drop")

# ======================================================================
# 14. Afleiden variabelen
# ======================================================================
microdata |>
  mutate(winstmarge = winst / na_if(omzet, 0),
         omzetgroei = (omzet - omzet_vorig) / na_if(omzet_vorig, 0))

# ======================================================================
# 15. Koppelen op foreign key
# ======================================================================
resultaat <- bedrijven |>
  left_join(gemeenten, by = "gemeente_code", relationship = "many-to-one")

# ======================================================================
# 16. Koppelen op primaire sleutel
# ======================================================================
resultaat <- left_join(d1, d2, by = "id", relationship = "one-to-one")
# right_join() | inner_join() | full_join()

# ======================================================================
# 17. Selectie van variabelen
# ======================================================================
selectie <- microdata |> select(id, sbi, omzet)
# alles behalve: select(-beroep_tekst, -gewicht)

# ======================================================================
# 18. Omcoderen
# ======================================================================
omgecodeerd <- persoon_data |>
  left_join(bsn_rin, by = "bsn") |>
  select(-bsn)

rin_project <- tibble(rin = unique(bsn_rin$rin)) |>             # verprinnen
  mutate(project_rin = sample(n()))

# ======================================================================
# 19. Selectie van eenheden
# ======================================================================
selectie <- microdata |>
  filter(str_starts(sbi, "47"), omzet >= 100000, gemeente %in% c("0363", "0599"))

# ======================================================================
# 20. Samenvoegen (complementeren)
# ======================================================================
samen <- bind_rows(dataset_a, dataset_b)
# zonder dubbelen: distinct()
