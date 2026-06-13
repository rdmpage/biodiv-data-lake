#!/bin/sh
#
# Convert the Catalogue of Life ColDP export (extended ColDP, tab-separated TSVs)
# to Parquet, one file per table. Source dataset 315192:
#   https://api.checklistbank.org/dataset/315192/export.zip?extended=true&format=ColDP
# Unzip export.zip into col/ first, then run from the repo root:
#
#   ./col/build_parquet.sh
#
# Writes col/<Table>.parquet (zstd). All columns kept as VARCHAR for fidelity:
# ColDP headers carry col:/clb: prefixes and many fields hold literal double
# quotes, so we parse with quote='' (no quoting). For each table we assert the
# Parquet row count equals the raw data-line count (file lines minus header) —
# i.e. no embedded newlines and nothing silently dropped. Adapter views that map
# col:/clb: columns to canonical names live in ../views.sql (prefixed col_).
set -eu

DUCKDB="${DUCKDB:-duckdb}"
# The two tables we use. Add others (Distribution VernacularName TypeMaterial …)
# as the lake grows — same parse rules apply to every ColDP table.
TABLES="NameUsage Reference"

for t in $TABLES; do
  src="col/$t.tsv"
  if [ ! -f "$src" ]; then echo "!! missing $src — skipping" >&2; continue; fi
  echo "== $t -> col/$t.parquet"
  "$DUCKDB" -c "
    PRAGMA memory_limit='8GB';
    PRAGMA temp_directory='.tmp';
    COPY (
      SELECT * FROM read_csv('$src', delim='\t', header=true, quote='', all_varchar=true)
    ) TO 'col/$t.parquet' (FORMAT parquet, COMPRESSION zstd);
  "
  raw=$("$DUCKDB" -csv -noheader -c "SELECT count(*)-1 FROM read_csv('$src', delim=chr(0), header=false, all_varchar=true)")
  got=$("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_parquet('col/$t.parquet')")
  if [ "$raw" != "$got" ]; then
    echo "!! $t fidelity FAIL: $got parquet rows vs $raw data lines" >&2; exit 1
  fi
  echo "   ok: $got rows"
done
echo "== done"
