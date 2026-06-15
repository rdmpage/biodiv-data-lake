# Charts (chart recipes)

The lake's **output layer**: turn a query into a chart. A *recipe* is a pair —
`<name>.sql` (a DuckDB query) + `<name>.vl.json` (a Vega-Lite spec template) —
following the "charts as metadata" idea (Deagen et al. 2022, see
`../reading/s41597-022-01352-z/` and `../output-layer-plan.md`), with **SQL in
place of SPARQL**.

## Render

```sh
./charts/build_chart.sh <name>          # e.g. funder_choropleth
```

Runs the SQL against `lake.duckdb` (loading `views.sql`) and inlines the result
rows into the spec, writing a self-contained `charts/out/<name>.vl.json`. Open it
in the [Vega-Lite editor](https://vega.github.io/editor) or embed with
[vega-embed](https://github.com/vega/vega-embed). Needs `duckdb` + `jq`.
`charts/out/` is gitignored (regenerable); recipes are version-controlled.

## Offline viewing (HTML)

`build_chart.sh` also writes `charts/out/<name>.html` — a standalone page that
inlines the spec and loads Vega from **local** files, so you can open it in a
browser with no editor and no server. Drop these three into `charts/` once
(gitignored):

```sh
curl -L -o charts/vega.min.js       https://cdn.jsdelivr.net/npm/vega@5/build/vega.min.js
curl -L -o charts/vega-lite.min.js  https://cdn.jsdelivr.net/npm/vega-lite@5/build/vega-lite.min.js
curl -L -o charts/vega-embed.min.js https://cdn.jsdelivr.net/npm/vega-embed@6/build/vega-embed.min.js
```

Then just open `charts/out/<name>.html`.

> Caveat: `funder_choropleth` still fetches the world-110m topojson from a CDN, so
> the *map outline* needs network. For fully-offline, download `world-110m.json`
> into `charts/` and point the template's `data.url` at `../world-110m.json`.
> Inline-data charts (bars, lines) are fully offline already.

## How a recipe works

- The **query** returns exactly the rows the chart needs.
- The **template** is an ordinary Vega-Lite spec, except its data slot holds the
  JSON string `"@@ROWS@@"`. The generator (`jq walk`) replaces that string with
  the query rows — uniform across chart types (a choropleth inlines into a
  `lookup` transform, a bar chart into `data.values`, etc.).
- Identifiers in the rows (DOI/ORCID/ROR) can become clickable marks via
  Vega-Lite's `href` encoding channel.

## Recipes

- **`funder_choropleth`** — world map of the countries funding papers that cite
  BOLD datasets. Path: `crossref_funder` → `ofr_funder` → `geonames_country`
  (`iso_numeric`), joined to the world-110m topojson `id`. 54 countries;
  Canada (96) / US (66) / Germany (59) lead.
