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
echo "wrote charts/out/$r.vl.json ($(printf '%s' "$rows" | jq 'length') rows)"
