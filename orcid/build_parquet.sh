#!/bin/sh
#
# Download and process the ORCID public-data-file SUMMARIES into Parquet.
# Source: figshare file 58834837 (ORCID_2025_10_summaries.tar.gz, ~46 GB).
# Run from the repo root:
#
#   ./orcid/build_parquet.sh
#
# Three stages: (1) resumable download, (2) stream-parse the whole tar to TSV
# (never extracting the 20M+ tiny XML files), (3) TSV -> Parquet. Adapter views
# orcid_person / orcid_work are in ../views.sql. The parse is single-threaded
# Python over ~20M records — expect a few hours; it logs progress per million.
# Generated orcid/*.tsv and orcid/*.parquet are gitignored.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
TARBALL="orcid/ORCID_2025_10_summaries.tar.gz"
URL="https://ndownloader.figshare.com/files/58834837"

# 1. download (resumable). Always hit the ndownloader URL — it re-signs a fresh,
#    short-lived S3 redirect each time; the api.figshare.com/v2/file/download/<id>
#    form 302s to the same place. (Same figshare quirk as the OpenCitations dl.)
if [ ! -f "$TARBALL" ]; then
  echo "== downloading $TARBALL"
  curl -fL -C - --retry 8 --retry-delay 5 --retry-connrefused -A "Mozilla/5.0" \
       -o "$TARBALL" "$URL"
fi

# 2. stream-parse the whole tarball -> orcid/orcid_{person,work}.tsv
echo "== parsing $TARBALL (streaming; ~hours)"
python3 orcid/parse_summaries.py "$TARBALL" orcid/orcid

# 3. TSV -> Parquet (all VARCHAR for fidelity; doi already lowercased by parser)
echo "== TSV -> Parquet"
"$DUCKDB" -c "
  PRAGMA memory_limit='8GB';
  PRAGMA temp_directory='.tmp';
  COPY (SELECT * FROM read_csv('orcid/orcid_person.tsv', delim='\t', header=true, quote='', all_varchar=true))
    TO 'orcid/orcid_person.parquet' (FORMAT parquet, COMPRESSION zstd);
  COPY (SELECT * FROM read_csv('orcid/orcid_work.tsv', delim='\t', header=true, quote='', all_varchar=true))
    TO 'orcid/orcid_work.parquet' (FORMAT parquet, COMPRESSION zstd);
"
echo "== done (orcid_person.parquet, orcid_work.parquet)"
