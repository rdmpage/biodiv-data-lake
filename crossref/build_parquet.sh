#!/bin/sh
#
# Build Parquet for the lake from cached Crossref works.
# Two steps: fetch (PHP, into crossref/cache/) then this build. Run from repo root:
#
#   CROSSREF_MAILTO=you@example.org php crossref/fetch.php <doi-list.txt>
#   ./crossref/build_parquet.sh
#
# build.php flattens crossref/cache/**/*.json -> four TSVs; this converts them to
# crossref_{work,author,funder,reference}.parquet. Adapter views crossref_* are
# in ../views.sql. Re-run after fetching more DOIs (it rebuilds from the cache).
# crossref/cache/, *.tsv, *.parquet, failed.txt are gitignored.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
echo "== flattening cache -> TSV"
php crossref/build.php

echo "== TSV -> Parquet"
for t in work author funder reference; do
  "$DUCKDB" -c "
    COPY (SELECT * FROM read_csv('crossref/crossref_${t}.tsv', delim='\t', header=true, quote='', all_varchar=true))
      TO 'crossref/crossref_${t}.parquet' (FORMAT parquet, COMPRESSION zstd);"
done
echo "== done"
