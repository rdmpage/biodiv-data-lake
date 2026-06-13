-- Precomputed helpers for OpenCitations. Run from the repo root:
--     duckdb -c ".read opencitations/build_stats.sql"
-- Outputs two small Parquet files exposed as views in ../views.sql.

PRAGMA memory_limit='28GB';
PRAGMA temp_directory='.tmp';

-- work_stats: in/out degree per work (OMID-keyed), single aggregation pass.
-- n_cited_by   = how many times the work is cited (in-degree)
-- n_references = how many works it cites (out-degree)
COPY (
  SELECT omid,
         sum(is_in)  AS n_cited_by,
         sum(is_out) AS n_references
  FROM (
    SELECT citing AS omid, 0 AS is_in, 1 AS is_out
      FROM read_parquet('opencitations/opencitations.parquet')
    UNION ALL
    SELECT cited  AS omid, 1 AS is_in, 0 AS is_out
      FROM read_parquet('opencitations/opencitations.parquet')
  )
  GROUP BY omid
) TO 'opencitations/work_stats.parquet' (FORMAT parquet, COMPRESSION zstd);

-- doi_omid: map every work that has a DOI to its OMID (lowercase DOIs).
COPY (
  SELECT nullif(lower(regexp_extract(id, 'doi:(\S+)', 1)), '') AS doi,
         split_part(id, ' ', 1)                                AS omid
  FROM read_parquet('opencitations/opencitations_meta.parquet')
  WHERE regexp_matches(id, 'doi:')
) TO 'opencitations/doi_omid.parquet' (FORMAT parquet, COMPRESSION zstd);
