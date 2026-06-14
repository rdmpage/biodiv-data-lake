#!/bin/sh
#
# Convert the Open Funder Registry RDF (FundRef SKOS) to Parquet.
# Source: Crossref Open Funder Registry, registry.rdf (CC0),
#   https://gitlab.com/crossref/open_funder_registry
# Drop registry.rdf in ofr/, then run from the repo root:
#
#   ./ofr/build_parquet.sh
#
# registry.rdf is one ~90 MB RDF/XML SKOS document; parse_registry.py streams it
# (xml.etree.iterparse) to a TSV. Adapter view `ofr_funder` is in ../views.sql.
# Generated ofr/*.tsv and ofr/*.parquet are gitignored.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
[ -f ofr/registry.rdf ] || { echo "!! ofr/registry.rdf not found — download it first" >&2; exit 1; }

echo "== parsing ofr/registry.rdf"
python3 ofr/parse_registry.py ofr/registry.rdf ofr/ofr_funder.tsv

echo "== TSV -> Parquet"
"$DUCKDB" -c "
  COPY (SELECT * FROM read_csv('ofr/ofr_funder.tsv', delim='\t', header=true, quote='', all_varchar=true))
    TO 'ofr/ofr_funder.parquet' (FORMAT parquet, COMPRESSION zstd);"
echo "== done ($("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_parquet('ofr/ofr_funder.parquet')") funders)"
