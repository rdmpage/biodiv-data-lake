#!/bin/sh
#
# Render a chart recipe: run its SQL against the lake and inline the result rows
# into its Vega-Lite spec, producing a self-contained spec in charts/out/.
#
#   ./charts/build_chart.sh funder_choropleth
#
# A recipe is a pair: charts/<name>.sql (a query) + charts/<name>.vl.json (a
# Vega-Lite spec template). The template marks the data slot with the JSON string
# "@@ROWS@@"; this script replaces it with the query rows (jq walk). Open the
# output in the Vega-Lite editor (vega.github.io/editor) or embed with vega-embed.
# Needs duckdb + jq. charts/out/ is gitignored (regenerable); recipes are tracked.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
r="${1:?usage: build_chart.sh <recipe-name>}"
[ -f "charts/$r.sql" ] && [ -f "charts/$r.vl.json" ] || {
  echo "!! charts/$r.sql and charts/$r.vl.json required" >&2; exit 1; }

mkdir -p charts/out
# views.sql first (CREATE VIEW emits nothing in -json), then the recipe query.
rows=$(cat views.sql "charts/$r.sql" | "$DUCKDB" lake.duckdb -json)
jq --argjson rows "$rows" 'walk(if . == "@@ROWS@@" then $rows else . end)' \
   "charts/$r.vl.json" > "charts/out/$r.vl.json"

# Also emit a standalone HTML that embeds the spec via local Vega JS (offline view).
# Put vega.min.js, vega-lite.min.js, vega-embed.min.js in charts/ (see README).
out="charts/out/$r.html"
cat > "$out" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>chart</title>
<script src="../vega.min.js"></script>
<script src="../vega-lite.min.js"></script>
<script src="../vega-embed.min.js"></script>
<style>body{font-family:sans-serif;margin:1rem}</style>
</head><body>
<div id="vis"></div>
<script>
const spec =
HTML
cat "charts/out/$r.vl.json" >> "$out"
cat >> "$out" <<'HTML'
;
vegaEmbed('#vis', spec).catch(console.error);
</script>
</body></html>
HTML
echo "wrote charts/out/$r.vl.json + charts/out/$r.html ($(printf '%s' "$rows" | jq 'length') rows)"
