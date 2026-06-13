#!/bin/sh
#
# Convert the OpenCitations Meta dump (output_csv_2026_01_14.tar.gz) into a
# single Parquet file.
#
#   ./build_meta_parquet.sh
#
# The tarball holds ~40k output_*.csv files. We extract them to a directory,
# then let DuckDB read the whole glob in one COPY. All columns kept as VARCHAR
# (id/author/venue are multi-valued strings; split later in queries).
#
set -u

DUCKDB="${DUCKDB:-duckdb}"
TARBALL="output_csv_2026_01_14.tar.gz"
DIR="output_csv_2026_01_14"
OUT="opencitations_meta.parquet"

COLS="{'id':'VARCHAR','title':'VARCHAR','author':'VARCHAR','issue':'VARCHAR','volume':'VARCHAR','venue':'VARCHAR','page':'VARCHAR','pub_date':'VARCHAR','type':'VARCHAR','publisher':'VARCHAR','editor':'VARCHAR'}"

if [ ! -d "$DIR" ]; then
  echo "== extracting $TARBALL"
  tar xzf "$TARBALL"
fi

echo "== csv files: $(ls -1 "$DIR"/*.csv 2>/dev/null | wc -l)"

echo "== writing $OUT"
"$DUCKDB" -c "
  COPY (
    SELECT * FROM read_csv('$DIR/*.csv', header=true, columns=$COLS,
                           quote='\"', escape='\"')
  ) TO '$OUT' (FORMAT parquet, COMPRESSION zstd);
"

echo "== done: $OUT"
"$DUCKDB" -c "SELECT count(*) AS works FROM read_parquet('$OUT');"
