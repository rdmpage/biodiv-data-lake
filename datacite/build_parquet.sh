#!/bin/sh
#
# Extract the DataCite DOI list (from the per-month CSVs in the Public Data File
# tar) to Parquet. The 615 GB of JSONL metadata is never read. Run from repo root:
#
#   ./datacite/build_parquet.sh [path-to.tar]
#
# Default tar: datacite/DataCite_Public_Data_File_2025.tar. Adapter view
# datacite_doi is in ../views.sql. Generated datacite/*.tsv and *.parquet, and
# the tar itself, are gitignored. For metadata of specific DOIs later, scan the
# JSONL in the matching `source` (updated_YYYY-MM) folder of the tar.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
TAR="${1:-datacite/DataCite_Public_Data_File_2025.tar}"
[ -f "$TAR" ] || { echo "!! $TAR not found" >&2; exit 1; }

echo "== extracting DOI list (csv.gz members only) from $TAR"
python3 datacite/extract_dois.py "$TAR" datacite/datacite_doi.tsv

echo "== TSV -> Parquet"
"$DUCKDB" -c "
  PRAGMA memory_limit='8GB'; PRAGMA temp_directory='.tmp';
  COPY (SELECT * FROM read_csv('datacite/datacite_doi.tsv', delim='\t', header=true, quote='', all_varchar=true))
    TO 'datacite/datacite_doi.parquet' (FORMAT parquet, COMPRESSION zstd);"
echo "== done ($("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_parquet('datacite/datacite_doi.parquet')") dois)"
