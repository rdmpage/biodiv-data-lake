#!/bin/sh
#
# Download and process the Zenodo metadata dump into normalised Parquet tables,
# filtered to the target communities (default: biosyslit, bionomia).
# Source: https://zenodo.org/api/exporter/records-xml.tar.gz (OAI-DataCite XML,
# one <id>.xml per record; see https://developers.zenodo.org/#list-available-dumps).
# Run from the repo root:
#
#   ./zenodo/build_parquet.sh
#
# The dump is a generated stream (no Content-Length, no Range/resume), so the
# download is one shot; --retry restarts on failure. The whole dump (all of
# Zenodo) is kept on disk so other communities can be re-filtered later. Parsing
# byte-pre-filters to the target communities, so only that slice is parsed.
# Generated zenodo/*.tsv and zenodo/*.parquet are gitignored.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
TARBALL="zenodo/records-xml.tar.gz"
URL="https://zenodo.org/api/exporter/records-xml.tar.gz"
COMMUNITIES="${ZENODO_COMMUNITIES:-biosyslit,bionomia}"

if [ ! -f "$TARBALL" ]; then
  echo "== downloading $TARBALL"
  curl -fL --retry 5 --retry-delay 10 --retry-all-errors -A "Mozilla/5.0 (Macintosh)" \
       -H "Accept: application/gzip" -o "$TARBALL" "$URL"
fi

echo "== parsing $TARBALL (communities: $COMMUNITIES)"
python3 zenodo/parse_records.py "$TARBALL" zenodo/zenodo "$COMMUNITIES"

echo "== TSV -> Parquet"
for t in record creator related subject description; do
  "$DUCKDB" -c "
    PRAGMA memory_limit='8GB'; PRAGMA temp_directory='.tmp';
    COPY (SELECT * FROM read_csv('zenodo/zenodo_${t}.tsv', delim='\t', header=true, quote='', all_varchar=true))
      TO 'zenodo/zenodo_${t}.parquet' (FORMAT parquet, COMPRESSION zstd);"
done
echo "== done; adapter views zenodo_* are in ../views.sql"
