# Business functies – Python (pandas). Verwacht dataframe `df` (= microdata) en overige tabellen als dataframes.
import numpy as np
import pandas as pd

# ======================================================================
# 1. Controleren validiteit
# ======================================================================
df["leeftijd_valide"] = df["leeftijd"].between(0, 120)            # NaN -> False
df["sbi_valide"] = df["sbi"].isin(["47111", "47112", "56101"])

# ======================================================================
# 2. Afleiden variabelen (typeren)
# ======================================================================
t = df["beroep_tekst"].str.lower()
df["beroepsgroep"] = np.select(
    [t.str.contains("verpleeg|arts|zorg", na=False),
     t.str.contains("leraar|docent|onderwijs", na=False)],
    ["Zorg", "Onderwijs"], default="Overig")
df.loc[t.isna(), "beroepsgroep"] = None

# ======================================================================
# 3. Afleiden variabelen (indikken)
# ======================================================================
df = df.merge(codelijst_indikking.rename(columns={"code_detail": "sbi", "code_ingedikt": "sbi_ingedikt"}),
              on="sbi", how="left")
# variant: df["sbi_2"] = df["sbi"].str[:2]

# ======================================================================
# 4. Controle op validiteit: algemene set controleregels
# ======================================================================
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

# ======================================================================
# 5. Imputatie
# ======================================================================
donor = df[df["omzet"].notna() & (df["personeel"] > 0)]
som = donor.groupby("sbi")[["omzet", "personeel"]].sum()
ratio = df["sbi"].map(som["omzet"] / som["personeel"])

df["omzet_is_geimputeerd"] = df["omzet"].isna() & (df["personeel"] * ratio).notna()
df["omzet_geimputeerd"] = df["omzet"].fillna(df["personeel"] * ratio)

# ======================================================================
# 6. Afleiden variabelen algemeen
# ======================================================================
df = df.assign(
    omzet_per_werknemer=df["omzet"] / df["personeel"].where(df["personeel"] != 0),
    grootteklasse=pd.cut(df["personeel"], [-np.inf, 10, 100, np.inf], labels=["klein", "midden", "groot"], right=False),
    sbi_2=df["sbi"].str[:2],
    is_zorg=df["beroep_tekst"].str.lower().str.contains("zorg|arts", na=False),
)

# ======================================================================
# 7. Controle op invloed en verdachtheid
# ======================================================================
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

# ======================================================================
# 8. Afleiden variabelen (omzetten meetschaal)
# ======================================================================
df["omzetklasse"] = pd.cut(df["omzet"], bins=[-np.inf, 1e5, 1e6, np.inf],
                           labels=["1: klein", "2: midden", "3: groot"], right=False, ordered=True)

# ======================================================================
# 9. Wegen / ophogen
# ======================================================================
n_steekproef = df.groupby("sbi")["id"].transform("count")
n_pop = df["sbi"].map(populatie.set_index("sbi")["n_pop"])
df["gewicht_nieuw"] = n_pop / n_steekproef

# ======================================================================
# 10. Aggregatie
# ======================================================================
agg = (df.assign(omzet_gew=df["omzet"] * df["gewicht"])
         .groupby(["sbi", "gemeente"], as_index=False)
         .agg(aantal_eenheden=("id", "count"), aantal_geschat=("gewicht", "sum"),
              omzet_gewogen=("omzet_gew", "sum"), omzet_ongewogen=("omzet", "sum")))

# ======================================================================
# 11. Inpassen (Stone)
# ======================================================================
def stone(x, A, b, V=None):
    x = np.asarray(x, float)
    V = np.diag(x) if V is None else V
    return x + V @ A.T @ np.linalg.solve(A @ V @ A.T, np.asarray(b, float) - A @ x)

A = np.array([[1.0, 1.0, 1.0]])                                   # loon + inkoop + overig
rij = df[["loon", "inkoop", "overig", "totaal"]].to_numpy(float)
df[["loon_ingepast", "inkoop_ingepast", "overig_ingepast"]] = [stone(r[:3], A, [r[3]]) for r in rij]

# ======================================================================
# 12. Controle op plausibiliteit
# ======================================================================
q1 = df.groupby("sbi")["omzet"].transform(lambda s: s.quantile(0.25))
q3 = df.groupby("sbi")["omzet"].transform(lambda s: s.quantile(0.75))
iqr = q3 - q1
df["omzet_plausibel"] = df["omzet"].between(q1 - 1.5 * iqr, q3 + 1.5 * iqr)

# ======================================================================
# 13. Afleiden variabelen en eenheden
# ======================================================================
huishoudens = (personen.assign(kind=personen["leeftijd"] < 18)
               .groupby("huishouden_id", as_index=False)
               .agg(aantal_personen=("persoon_id", "count"), gem_leeftijd=("leeftijd", "mean"),
                    leeftijd_oudste=("leeftijd", "max"), aantal_kinderen=("kind", "sum"),
                    huishoudinkomen=("inkomen", "sum")))

# ======================================================================
# 14. Afleiden variabelen
# ======================================================================
df["winstmarge"] = df["winst"] / df["omzet"].where(df["omzet"] != 0)
df["omzetgroei"] = (df["omzet"] - df["omzet_vorig"]) / df["omzet_vorig"].where(df["omzet_vorig"] != 0)

# ======================================================================
# 15. Koppelen op foreign key
# ======================================================================
resultaat = bedrijven.merge(gemeenten, on="gemeente_code", how="left", validate="m:1")

# ======================================================================
# 16. Koppelen op primaire sleutel
# ======================================================================
resultaat = d1.merge(d2, on="id", how="left", validate="1:1")   # "right" | "inner" | "outer"

# ======================================================================
# 17. Selectie van variabelen
# ======================================================================
selectie = df[["id", "sbi", "omzet"]]
# alles behalve: df.drop(columns=["beroep_tekst", "gewicht"])

# ======================================================================
# 18. Omcoderen
# ======================================================================
omgecodeerd = (persoon_data.merge(bsn_rin, on="bsn", how="left")
                           .drop(columns="bsn"))

rng = np.random.default_rng()                                   # verprinnen
rin_project = pd.DataFrame({"rin": bsn_rin["rin"].unique()})
rin_project["project_rin"] = rng.permutation(len(rin_project)) + 1

# ======================================================================
# 19. Selectie van eenheden
# ======================================================================
selectie = df[df["sbi"].str.startswith("47") & (df["omzet"] >= 100_000) & df["gemeente"].isin(["0363", "0599"])]

# ======================================================================
# 20. Samenvoegen (complementeren)
# ======================================================================
samen = pd.concat([dataset_a, dataset_b], ignore_index=True)
# zonder dubbelen: .drop_duplicates()
