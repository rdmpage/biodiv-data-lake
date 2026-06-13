#!/bin/sh
#
# Convert the BHL Open Data relational export (tab-separated .txt.gz dumps,
# https://registry.opendata.aws/bhl-open-data/) to Parquet, one table each.
#
#   BHL_SRC="/path/to/BHL AWS.localized/data" ./bhl/build_parquet.sh
#
# Run from the repo root; writes bhl/<table>.parquet (zstd). All columns kept as
# VARCHAR for fidelity (source is tab-delimited, unquoted, UTF-8 with BOM; fields
# have no embedded tabs/newlines — verified row counts match line counts).
set -eu

BHL_SRC="${BHL_SRC:?set BHL_SRC to the mounted BHL data folder}"
DUCKDB="${DUCKDB:-duckdb}"

# bibliographic core + bridge first (small), then the big page/name layer
TABLES="title item part doi creator partcreator partpage partidentifier titleidentifier creatoridentifier subject page pagename"

mkdir -p bhl
for t in $TABLES; do
  src="$BHL_SRC/$t.txt.gz"
  if [ ! -f "$src" ]; then echo "!! missing $src — skipping" >&2; continue; fi
  echo "== $t -> bhl/$t.parquet"
  "$DUCKDB" -c "
    PRAGMA memory_limit='28GB';
    PRAGMA temp_directory='.tmp';
    COPY (
      SELECT * FROM read_csv('$src', delim='\t', header=true, quote='', all_varchar=true)
    ) TO 'bhl/$t.parquet' (FORMAT parquet, COMPRESSION zstd);
  "
done
echo "== done"
