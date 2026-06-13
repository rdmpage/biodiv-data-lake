-- =============================================================================
-- Biodiversity / bibliographic data lake — adapter views (Silver layer)
-- =============================================================================
-- Source of truth for column-name mappings. Raw Parquet is never modified.
-- Rebuild the catalog any time with:
--     cd /Volumes/Acer/biodiv-data-lake-o
--     duckdb lake.duckdb -c ".read views.sql"
-- Paths are relative to the lake root, so always open duckdb from there.
--
-- Naming leans on bibliographic conventions (DOI/title/authors/venue) so the
-- columns are legible and join cleanly to other sources later.
-- =============================================================================

-- --- OpenCitations Meta: one row per bibliographic work ----------------------
-- Raw `id` packs several identifiers, space-separated, OMID first, e.g.
--   "omid:br/0690942028 openalex:W1998836856 doi:10.1016/... pmid:21963310"
-- We pull each identifier out into its own column. DOIs are stored lowercase.
CREATE OR REPLACE VIEW works AS
SELECT
  split_part(id, ' ', 1)                                AS omid,
  nullif(lower(regexp_extract(id, 'doi:(\S+)', 1)), '') AS doi,
  nullif(regexp_extract(id, 'pmid:(\S+)', 1), '')       AS pmid,
  nullif(regexp_extract(id, 'openalex:(\S+)', 1), '')   AS openalex,
  title,
  author                                                AS authors,
  venue,
  volume,
  issue,
  page,
  pub_date,
  type,
  publisher,
  editor,
  id                                                    AS raw_id
FROM read_parquet('opencitations/opencitations_meta.parquet');

-- --- OpenCitations Index: one row per citation (an edge between two works) ---
CREATE OR REPLACE VIEW citations AS
SELECT
  citing             AS citing_omid,
  cited              AS cited_omid,
  creation           AS created,        -- date the citing work was published
  timespan,                              -- ISO-8601 gap, e.g. P41Y
  journal_sc = 'yes' AS journal_self_citation,
  author_sc  = 'yes' AS author_self_citation,
  id                 AS oci
FROM read_parquet('opencitations/opencitations.parquet');

-- --- Convenience: citations with both endpoints resolved to DOIs -------------
-- Lets you filter citations directly by DOI: WHERE cited_doi = '10.xxx'.
-- NOTE: this joins works onto 2.3B citation rows on the fly, so a query that
-- scans it takes ~1-2 min. For repeated DOI lookups, prefer the Gold table
-- approach (see README) which precomputes counts.
CREATE OR REPLACE VIEW citations_resolved AS
SELECT
  c.citing_omid,
  cw.doi AS citing_doi,
  c.cited_omid,
  dw.doi AS cited_doi,
  c.created,
  c.timespan,
  c.journal_self_citation,
  c.author_self_citation,
  c.oci
FROM citations c
LEFT JOIN works cw ON c.citing_omid = cw.omid
LEFT JOIN works dw ON c.cited_omid  = dw.omid;

-- =============================================================================
-- Precomputed helpers (build once: duckdb -c ".read opencitations/build_stats.sql")
-- =============================================================================

-- doi_omid (Silver): one row per work that has a DOI. Small; join lists of DOIs
-- (e.g. BHL) onto this to reach OMIDs, then onto work_stats / citations.
CREATE OR REPLACE VIEW doi_omid AS
SELECT doi, omid
FROM read_parquet('opencitations/doi_omid.parquet');

-- work_stats (Gold): in/out degree per work (OMID-keyed).
--   n_cited_by   = times the work is cited        (in-degree)
--   n_references = number of works it cites        (out-degree)
CREATE OR REPLACE VIEW work_stats AS
SELECT omid, n_cited_by, n_references
FROM read_parquet('opencitations/work_stats.parquet');

-- =============================================================================
-- Ergonomic macros for casual DOI queries
-- =============================================================================
-- NOTE: these list the actual citing/cited works, so they scan the 38 GB
-- citations file (~20 s). For just the COUNT, join work_stats (instant) instead.

-- Works that CITE this DOI (its citers).
CREATE OR REPLACE MACRO cited_by(p_doi) AS TABLE
  SELECT cm.doi AS citing_doi, w.title, w.pub_date, c.citing_omid
  FROM doi_omid m
  JOIN citations c   ON c.cited_omid = m.omid
  LEFT JOIN works w  ON w.omid  = c.citing_omid
  LEFT JOIN doi_omid cm ON cm.omid = c.citing_omid
  WHERE m.doi = lower(p_doi);

-- Works this DOI CITES (its reference list).
CREATE OR REPLACE MACRO cites(p_doi) AS TABLE
  SELECT dm.doi AS cited_doi, w.title, w.pub_date, c.cited_omid
  FROM doi_omid m
  JOIN citations c   ON c.citing_omid = m.omid
  LEFT JOIN works w  ON w.omid  = c.cited_omid
  LEFT JOIN doi_omid dm ON dm.omid = c.cited_omid
  WHERE m.doi = lower(p_doi);

-- Citation count for a DOI (instant — reads work_stats, no citations scan).
CREATE OR REPLACE MACRO citation_count(p_doi) AS (
  SELECT coalesce(max(s.n_cited_by), 0)::BIGINT
  FROM doi_omid m
  LEFT JOIN work_stats s ON s.omid = m.omid
  WHERE m.doi = lower(p_doi)
);
