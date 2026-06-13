#!/bin/sh
#
# Convert the downloaded OpenCitations figshare zips into a single Parquet file.
#
#   ./build_parquet.sh
#
# Strategy (keeps peak disk low and is resumable):
#   1. For each <id>.zip: extract its CSVs to a temp dir, write parts/<id>.parquet,
#      then delete the temp CSVs. Skips ids whose part already exists.
#   2. Merge all parts/*.parquet into a single opencitations.parquet.
#
# All columns are kept as VARCHAR for fidelity (creation is partial dates like
# "1982-09", timespan is an ISO-8601 duration like "P9Y4M"). Cast later in queries.
#
set -u

DUCKDB="${DUCKDB:-duckdb}"
PARTS="parts"
TMP="csv_tmp"
OUT="opencitations.parquet"

mkdir -p "$PARTS"

COLS="{'id':'VARCHAR','citing':'VARCHAR','cited':'VARCHAR','creation':'VARCHAR','timespan':'VARCHAR','journal_sc':'VARCHAR','author_sc':'VARCHAR'}"

for zip in *.zip; do
  [ -e "$zip" ] || continue
  id="${zip%.zip}"
  part="$PARTS/$id.parquet"
  if [ -e "$part" ]; then
    echo "== skip $id (part exists)"
    continue
  fi
  echo "== $id: extracting"
  rm -rf "$TMP"
  mkdir -p "$TMP"
  if ! unzip -o -q -j "$zip" '*.csv' -d "$TMP"; then
    echo "!! unzip failed for $id" >&2
    continue
  fi
  echo "== $id: -> $part"
  "$DUCKDB" -c "
    COPY (
      SELECT * FROM read_csv('$TMP/*.csv', header=true, columns=$COLS)
    ) TO '$part' (FORMAT parquet, COMPRESSION zstd);
  " || { echo "!! duckdb failed for $id" >&2; rm -f "$part"; continue; }
  rm -rf "$TMP"
done

echo "== merging parts into $OUT"
"$DUCKDB" -c "
  COPY (
    SELECT * FROM read_parquet('$PARTS/*.parquet')
  ) TO '$OUT' (FORMAT parquet, COMPRESSION zstd);
"

echo "== done: $OUT"
"$DUCKDB" -c "SELECT count(*) AS rows FROM read_parquet('$OUT');"
