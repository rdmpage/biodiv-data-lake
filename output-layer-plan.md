# Output layer plan — getting usable results out of the lake

The lake can now answer rich cross-dataset questions in SQL, but expecting users
to write DuckDB SQL is daunting. This is the plan for the **output layer**: turn
queries into charts and put a conversational interface in front. Nothing here
needs the big/messy data (BOLD, GBIF, GenBank) — the **BOLD-citations example**
(`sandbox/bold-citations/`) is the testbed.

Foundation note: the lake's canonical adapter views (`views.sql`) + shared
identifiers (DOI, ORCID, ROR, FundRef) were deliberately set up to make all of
this easy — we get FAIR-graphics + LLM-over-SQL without a triple store.

## 1. Charts as metadata (Vega-Lite + SQL)

After Deagen et al. 2022, *FAIR and Interactive Data Graphics from a Scientific
Knowledge Graph* (`reading/s41597-022-01352-z/`), which pairs a **SPARQL query**
(semantic context) with a **Vega-Lite spec** (visual context). We swap SPARQL for
**DuckDB SQL**:

- A **chart recipe** = `(parameterised SQL, Vega-Lite spec template)`, stored as
  versioned files (a `charts/` folder, same ethos as `views.sql`).
- Run the SQL → DuckDB emits JSON rows → inline as `data.values` in the spec → a
  self-contained, openable chart that's always live against the Parquet.
- Marks link out via the Vega-Lite `href` channel using our identifiers
  (DOI/ORCID/ROR/FundRef as the "dereferenceable URIs").
- A tiny generator (DuckDB `-json` + template fill) produces ready-to-open specs.

First recipes (all from the BOLD example, data already present):
- **Choropleth** of funder countries (funder → ROR → country).
- **Bar** of top funders / author institutions.
- **Line** of BOLD-citing papers per year.

## 2. GeoNames as the geographic reconciliation spine

GeoNames reconciles geography across sources: ROR carries
`locations.geonames_id`; OFR's `svf:country`/`state` are GeoNames URIs; it also
later anchors GBIF occurrences. It's what reconciles FundRef's `"usa"` vs ROR's
`"US"` vs a GeoNames id.

- **Start tiny:** `countryInfo.txt` (~250 rows: ISO codes, name, centroid lat/lng,
  continent) — enough for country-level choropleths.
- **Defer** the full `allCountries` (place-level, admin hierarchy) until
  sub-country geography is actually needed.

## 3. MCP server in front of the lake

So users ask questions instead of writing SQL.

- **Thin (start here):** a `run_sql` tool + expose `views.sql` and table
  descriptions as MCP resources. Claude reads the canonical views and writes the
  SQL. Low effort, high power — this is what the adapter-view design enables.
- **Curated (layer on):** high-level tools (`citations_for(doi)`,
  `funders_for(doi_list)`, `disruption(doi)`) and a **`chart(question)`** tool
  returning a Vega-Lite spec. Endgame: *ask → SQL → rows → chart*, no SQL exposed.
- Off-the-shelf DuckDB MCP servers exist; a thin custom one (DuckDB + our views as
  context) is a small build and keeps control.

## Suggested sequence

1. ✅ `countryInfo.txt` (→ `geonames_country`) + first **chart recipe**
   (`charts/funder_choropleth`) as a `(SQL + Vega-Lite)` pair + the
   `charts/build_chart.sh` generator. Output layer proven end to end.
2. MCP `run_sql` prototype over `views.sql`.
3. Curated tools + `chart()` on top, as patterns emerge.

Then — and only then — the big, messy biology: **BOLD, GBIF, GenBank**.
