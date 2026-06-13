-- Build enriched, sorted copies of the works metadata for fast lookups.
-- Run from the repo root:  duckdb -c ".read opencitations/build_works_sorted.sql"
--
-- Identifiers (doi/omid/pmid/openalex) are extracted from the packed `id` once,
-- as real columns. Two physical sort orders => fast zonemap-pruned lookups on
-- either key:
--   works_by_doi.parquet   -> sorted by doi  (casual "record by DOI")
--   works_by_omid.parquet  -> sorted by omid (resolve citing/cited works)
-- Raw Meta parquet stays as the untouched Bronze source.

PRAGMA memory_limit='28GB';
PRAGMA temp_directory='.tmp';
SET preserve_insertion_order=true;

-- Enrich + sort by doi (NULL dois — works with no DOI — cluster at the end).
COPY (
  SELECT
    split_part(id, ' ', 1)                                AS omid,
    nullif(lower(regexp_extract(id, 'doi:(\S+)', 1)), '') AS doi,
    nullif(regexp_extract(id, 'pmid:(\S+)', 1), '')       AS pmid,
    nullif(regexp_extract(id, 'openalex:(\S+)', 1), '')   AS openalex,
    title,
    author                                                AS authors,
    venue, volume, issue, page, pub_date, type, publisher, editor,
    id                                                    AS raw_id
  FROM read_parquet('opencitations/opencitations_meta.parquet')
  ORDER BY doi
) TO 'opencitations/works_by_doi.parquet' (FORMAT parquet, COMPRESSION zstd);

-- Re-sort the enriched rows by omid (reuse copy 1 so we don't re-run the regex).
COPY (
  SELECT * FROM read_parquet('opencitations/works_by_doi.parquet')
  ORDER BY omid
) TO 'opencitations/works_by_omid.parquet' (FORMAT parquet, COMPRESSION zstd);
