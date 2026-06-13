#!/bin/sh
#
# Export OpenCitations data for a list of DOIs to a SQLite database — offline,
# in one pass, instead of hitting the OpenCitations API one DOI at a time.
#
# Exploration helper (sandbox). Once BHL metadata is itself in the lake, "BHL
# citations" is just a bhl <-> opencitations join and this script is unnecessary;
# it stays here as a generic DOI-list -> SQLite exporter for one-off external use.
#
#   ./sandbox/bhl-citations/doi_to_sqlite.sh <doi-file> <out.sqlite>
#
# <doi-file> is one DOI per line (case-insensitive; matched lowercase).
# MUST be run from the repo root — the OpenCitations parquet paths are relative
# to it (opencitations/*.parquet).
#
# Produces two tables in <out.sqlite>:
#   works     - one row per (doi, omid): title, pub_date, n_cited_by, n_references
#   citations - one row per incoming citation: cited_doi, citing_doi, dates, self-cites
#
# Note: a DOI can map to >1 OMID in OpenCitations Meta (duplicate work records),
# so `works` may have >1 row per DOI; aggregate to DOI level (GROUP BY doi, SUM)
# when computing per-DOI totals.
set -eu

DOIS="${1:?usage: doi_to_sqlite.sh <doi-file> <out.sqlite>}"
OUT="${2:?usage: doi_to_sqlite.sh <doi-file> <out.sqlite>}"
DUCKDB="${DUCKDB:-duckdb}"

rm -f "$OUT"
"$DUCKDB" -c "
INSTALL sqlite; LOAD sqlite;
PRAGMA memory_limit='28GB';
PRAGMA temp_directory='.tmp';
ATTACH '$OUT' AS s (TYPE sqlite);

-- input DOIs -> their OMID(s)
CREATE TEMP TABLE _map AS
  SELECT d.doi, m.omid
  FROM (SELECT DISTINCT lower(trim(column0)) AS doi
        FROM read_csv('$DOIS', header=false, columns={'column0':'VARCHAR'})) d
  JOIN read_parquet('opencitations/doi_omid.parquet') m ON m.doi = d.doi;

-- per-work metadata + degree stats
CREATE TABLE s.works AS
  SELECT mp.doi, mp.omid, w.title, w.pub_date, w.type,
         coalesce(st.n_cited_by, 0)   AS n_cited_by,
         coalesce(st.n_references, 0) AS n_references
  FROM _map mp
  LEFT JOIN read_parquet('opencitations/works_by_omid.parquet') w  ON w.omid  = mp.omid
  LEFT JOIN read_parquet('opencitations/work_stats.parquet')    st ON st.omid = mp.omid;

-- incoming citations (who cites each input DOI), with the citing work's DOI
CREATE TABLE s.citations AS
  SELECT mp.doi          AS cited_doi,
         c.cited         AS cited_omid,
         c.citing        AS citing_omid,
         cm.doi          AS citing_doi,
         c.creation      AS citing_date,
         c.timespan,
         c.journal_sc,
         c.author_sc
  FROM _map mp
  JOIN read_parquet('opencitations/opencitations.parquet') c ON c.cited = mp.omid
  LEFT JOIN read_parquet('opencitations/doi_omid.parquet') cm ON cm.omid = c.citing;
"

echo "== wrote $OUT"
"$DUCKDB" "$OUT" -c "
SELECT 'works' AS tbl, count(*) AS rows FROM works
UNION ALL SELECT 'citations', count(*) FROM citations;
"
