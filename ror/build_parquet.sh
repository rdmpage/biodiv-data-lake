#!/bin/sh
#
# Convert the ROR (Research Organization Registry) data dump to Parquet.
# Source: ROR dumps on Zenodo, community "ror-data" (record 20512981 = v2.8).
#   https://zenodo.org/records/20512981  (JSON + CSV in one zip; we use the CSV)
#
# NOTE: download the zip manually into ror/ — Zenodo rate-limits bulk/agent
# traffic (a big dump download will earn a 403 "unusual traffic" block), so this
# script does not fetch it. Drop ror/v*-ror-data.zip in place, then run from the
# repo root:
#
#   ./ror/build_parquet.sh
#
# ROR v2 CSV is RFC-4180 (comma-delimited, double-quoted — fields may contain
# commas/newlines), columns are dot-flattened, multi-valued fields ';'-separated.
# Adapter view `ror` is in ../views.sql. Generated ror/*.csv and ror/*.parquet
# are gitignored (reproducible from the zip).
set -eu

DUCKDB="${DUCKDB:-duckdb}"
ZIP=$(ls ror/v*-ror-data.zip 2>/dev/null | sort | tail -1 || true)
[ -n "$ZIP" ] || { echo "!! no ror/v*-ror-data.zip found — download from Zenodo first" >&2; exit 1; }

CSV=$(unzip -Z1 "$ZIP" | grep '\.csv$' | head -1)
echo "== extracting $CSV from $ZIP"
unzip -o "$ZIP" "$CSV" -d ror/ >/dev/null

echo "== $CSV -> ror/ror.parquet"
"$DUCKDB" -c "
  PRAGMA memory_limit='4GB';
  COPY (SELECT * FROM read_csv('ror/$CSV', all_varchar=true))
    TO 'ror/ror.parquet' (FORMAT parquet, COMPRESSION zstd);"
echo "== done ($("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_parquet('ror/ror.parquet')") orgs)"
