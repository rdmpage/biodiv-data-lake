-- Build physically-sorted copies of the citation edges for fast lookups.
-- Run from the repo root:  duckdb -c ".read opencitations/build_citations_sorted.sql"
--
-- The raw opencitations.parquet (2.3B edges) is in no useful order, so every
-- "who cites X" / "what does X cite" query scans all 38 GB (~20-40 s). Two sort
-- orders give zonemap-pruned, sub-second point lookups on either endpoint:
--   citations_by_cited.parquet   -> sorted by cited_omid  (citers / impact: cited_by, CD)
--   citations_by_citing.parquet  -> sorted by citing_omid (references: cites, CD refs)
-- Columns match the `citations` view, so the by_* views are drop-in.
-- Raw opencitations.parquet stays the untouched Bronze source.

PRAGMA memory_limit='28GB';
PRAGMA temp_directory='.tmp';

-- Sorted by cited_omid (rename packed columns to canonical names in one pass).
COPY (
  SELECT citing             AS citing_omid,
         cited              AS cited_omid,
         creation           AS created,
         timespan,
         journal_sc = 'yes' AS journal_self_citation,
         author_sc  = 'yes' AS author_self_citation,
         id                 AS oci
  FROM read_parquet('opencitations/opencitations.parquet')
  ORDER BY cited
) TO 'opencitations/citations_by_cited.parquet' (FORMAT parquet, COMPRESSION zstd);

-- Re-sort the already-renamed copy by citing_omid (cheaper than re-reading raw).
COPY (
  SELECT * FROM read_parquet('opencitations/citations_by_cited.parquet')
  ORDER BY citing_omid
) TO 'opencitations/citations_by_citing.parquet' (FORMAT parquet, COMPRESSION zstd);
