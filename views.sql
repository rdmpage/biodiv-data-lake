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
-- The identifiers (doi/omid/pmid/openalex) are extracted once into real columns
-- by opencitations/build_works_sorted.sql, which writes two physically-sorted
-- copies. `works` points at the doi-sorted copy so `WHERE doi = '...'` prunes
-- row groups (sub-second). For lookups/joins by OMID, use `works_by_omid`.
-- (Raw Meta parquet remains the untouched Bronze source; DOIs are lowercase.)
CREATE OR REPLACE VIEW works AS
SELECT * FROM read_parquet('opencitations/works_by_doi.parquet');

-- Same rows, sorted by omid: fast `WHERE omid = '...'` and omid-keyed joins.
CREATE OR REPLACE VIEW works_by_omid AS
SELECT * FROM read_parquet('opencitations/works_by_omid.parquet');

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

-- Physically-sorted copies of the edges (opencitations/build_citations_sorted.sql),
-- same columns as `citations`, for sub-second zonemap-pruned point lookups:
--   citations_by_cited  : sorted by cited_omid  -> "who cites X" (in-edges)
--   citations_by_citing : sorted by citing_omid -> "what does X cite" (out-edges)
-- Use the one whose sort key matches your WHERE/JOIN key; `citations` (unsorted)
-- is still the right choice for full scans that filter on neither endpoint.
CREATE OR REPLACE VIEW citations_by_cited AS
SELECT * FROM read_parquet('opencitations/citations_by_cited.parquet');
CREATE OR REPLACE VIEW citations_by_citing AS
SELECT * FROM read_parquet('opencitations/citations_by_citing.parquet');

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
LEFT JOIN works_by_omid cw ON c.citing_omid = cw.omid
LEFT JOIN works_by_omid dw ON c.cited_omid  = dw.omid;

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

-- GBIF occurrence downloads, OMID-keyed. GBIF mints a DOI per download
-- (10.15468/dl.* and custom downloads 10.15468/cdl.*) that machine-cites every
-- dataset the download draws from. These flood the citation graph — a popular
-- dataset accrues tens of thousands of download "citations" that aren't
-- literature. To measure literature impact, anti-join citing_omid against this:
--   ... LEFT JOIN gbif_download_omid g ON g.omid = c.citing_omid WHERE g.omid IS NULL
-- (~1.5M works; derived from doi_omid, ~4 s). See sandbox/bhl-oc-citations/.
CREATE OR REPLACE VIEW gbif_download_omid AS
SELECT DISTINCT omid FROM doi_omid WHERE doi LIKE '10.15468/%';

-- =============================================================================
-- Ergonomic macros for casual DOI queries
-- =============================================================================
-- NOTE: these list the actual citing/cited works via the sorted edge copies
-- (citations_by_cited / citations_by_citing), so they prune to sub-second. For
-- just the COUNT, join work_stats (instant, no edge scan at all) instead.

-- Works that CITE this DOI (its citers). In-edges -> citations_by_cited.
-- The sorted-column filter is a WHERE IN (subquery) (not a JOIN) so the OMID is
-- pushed down and parquet row groups prune (~1-2 s vs a ~20 s full scan).
CREATE OR REPLACE MACRO cited_by(p_doi) AS TABLE
  SELECT cm.doi AS citing_doi, w.title, w.pub_date, c.citing_omid
  FROM citations_by_cited c
  LEFT JOIN works_by_omid w ON w.omid  = c.citing_omid
  LEFT JOIN doi_omid cm ON cm.omid = c.citing_omid
  WHERE c.cited_omid IN (SELECT omid FROM doi_omid WHERE doi = lower(p_doi));

-- Works this DOI CITES (its reference list). Out-edges -> citations_by_citing.
CREATE OR REPLACE MACRO cites(p_doi) AS TABLE
  SELECT dm.doi AS cited_doi, w.title, w.pub_date, c.cited_omid
  FROM citations_by_citing c
  LEFT JOIN works_by_omid w ON w.omid  = c.cited_omid
  LEFT JOIN doi_omid dm ON dm.omid = c.cited_omid
  WHERE c.citing_omid IN (SELECT omid FROM doi_omid WHERE doi = lower(p_doi));

-- Single-record lookups (both prune via the sorted copies).
CREATE OR REPLACE MACRO work_by_doi(p_doi)  AS TABLE
  SELECT * FROM works         WHERE doi  = lower(p_doi);
CREATE OR REPLACE MACRO work_by_omid(p_omid) AS TABLE
  SELECT * FROM works_by_omid WHERE omid = p_omid;

-- Citation count for a DOI (instant — reads work_stats, no citations scan).
CREATE OR REPLACE MACRO citation_count(p_doi) AS (
  SELECT coalesce(max(s.n_cited_by), 0)::BIGINT
  FROM doi_omid m
  LEFT JOIN work_stats s ON s.omid = m.omid
  WHERE m.doi = lower(p_doi)
);

-- "Related" works by CO-CITATION: works most often cited together with this DOI
-- (i.e. sharing citers). Ordered most-related first; add a LIMIT when you call it.
-- Pass 1 (the focal's citers, by cited_omid) prunes nicely; pass 2 (everything
-- those citers cite, by citing_omid) touches many scattered row groups, so for a
-- highly-cited focal work this is still ~20 s — co-citation is inherently broad.
-- Bibliographic coupling (shared *references*) is a different notion — swap keys.
CREATE OR REPLACE MACRO related(p_doi) AS TABLE
  WITH focal AS (SELECT omid FROM doi_omid WHERE doi = lower(p_doi)),
  cocite AS (
    SELECT co.cited_omid AS omid, count(*) AS co_citations
    FROM citations_by_cited a
    JOIN citations_by_citing co ON co.citing_omid = a.citing_omid
    WHERE a.cited_omid = (SELECT omid FROM focal)
      AND co.cited_omid <> (SELECT omid FROM focal)
    GROUP BY co.cited_omid
  )
  SELECT cc.co_citations, w.doi, w.title, cc.omid
  FROM cocite cc
  LEFT JOIN works_by_omid w ON w.omid = cc.omid
  ORDER BY cc.co_citations DESC;

-- =============================================================================
-- BHL (Biodiversity Heritage Library) — adapter views over bhl/*.parquet
-- Source: BHL Open Data relational export. Raw columns kept; these rename to
-- snake_case canonical names. Build with bhl/build_parquet.sh.
-- =============================================================================

-- Bibliographic hierarchy: title (journal/book) -> item (volume) -> part (article)
CREATE OR REPLACE VIEW bhl_title AS
SELECT TitleID AS title_id, FullTitle AS full_title, ShortTitle AS short_title,
       PublicationDetails AS publication_details,
       StartYear AS start_year, EndYear AS end_year,
       LanguageCode AS language_code, TitleURL AS title_url, MARCBibID AS marc_bib_id
FROM read_parquet('bhl/title.parquet');

CREATE OR REPLACE VIEW bhl_item AS
SELECT ItemID AS item_id, TitleID AS title_id, BarCode AS barcode,
       VolumeInfo AS volume_info, Year AS year, ItemURL AS item_url,
       ItemPDFURL AS item_pdf_url, InstitutionName AS institution_name
FROM read_parquet('bhl/item.parquet');

CREATE OR REPLACE VIEW bhl_part AS
SELECT PartID AS part_id, ItemID AS item_id, SegmentType AS segment_type,
       Title AS title, ContainerTitle AS container_title,
       Volume AS volume, Series AS series, Issue AS issue, Date AS date,
       PageRange AS page_range, StartPageID AS start_page_id,
       SegmentUrl AS segment_url, ContributorName AS contributor_name
FROM read_parquet('bhl/part.parquet');

-- Polymorphic DOI bridge (EntityType in {Part, Title}); DOIs exposed lowercase
CREATE OR REPLACE VIEW bhl_doi AS
SELECT EntityType AS entity_type, EntityID AS entity_id, lower(DOI) AS doi
FROM read_parquet('bhl/doi.parquet');

-- Names layer: taxonomic names found on pages
CREATE OR REPLACE VIEW bhl_page AS
SELECT PageID AS page_id, ItemID AS item_id, Year AS year,
       Volume AS volume, PageNumber AS page_number, PageTypeName AS page_type
FROM read_parquet('bhl/page.parquet');

CREATE OR REPLACE VIEW bhl_pagename AS
SELECT NameConfirmed AS name, PageID AS page_id, NameBankID AS namebank_id
FROM read_parquet('bhl/pagename.parquet');

-- Joining BHL part DOIs to OpenCitations citation counts is kept as a worked
-- example under sandbox/bhl-oc-citations/ rather than as catalog views.

-- =============================================================================
-- Catalogue of Life (ColDP export) — adapter views over col/*.parquet
-- Source: ChecklistBank dataset 315192 (extended ColDP). Build with
-- col/build_parquet.sh. ColDP columns are namespaced (col:/clb:); these views
-- map the ones we use to canonical names and drop the prefixes. doi is cleaned
-- (lowercased/trimmed) so it joins bhl_doi.doi and opencitations doi_omid.doi.
-- =============================================================================

-- Bibliographic references cited by COL name usages.
CREATE OR REPLACE VIEW col_reference AS
SELECT "col:ID"             AS reference_id,
       "col:citation"       AS citation,
       "col:author"         AS author,
       "col:title"          AS title,
       "col:containerTitle" AS container_title,
       "col:issued"         AS issued,
       "col:volume"         AS volume,
       "col:issue"          AS issue,
       "col:page"           AS page,
       lower(nullif(trim("col:doi"), '')) AS doi,   -- canonical: lowercase, blanks->NULL
       "col:doi"            AS raw_doi,
       "col:issn"           AS issn,
       "col:isbn"           AS isbn,
       "col:link"           AS link,
       "col:type"           AS type,
       "col:sourceID"       AS source_id
FROM read_parquet('col/Reference.parquet');

-- Taxonomic name usages (taxa + synonyms): the backbone. Higher classification
-- is denormalised on each row (kingdom..genus). nameReferenceID -> col_reference
-- is the original-description link (name -> literature -> BHL/OpenCitations).
CREATE OR REPLACE VIEW col_name_usage AS
SELECT "col:ID"                   AS usage_id,
       "col:parentID"             AS parent_id,
       "col:basionymID"           AS basionym_id,
       "col:status"               AS status,
       "col:scientificName"       AS scientific_name,
       "col:authorship"           AS authorship,
       "col:rank"                 AS rank,
       "col:code"                 AS nomenclatural_code,
       "col:genericName"          AS generic_name,
       "col:specificEpithet"      AS specific_epithet,
       "col:infraspecificEpithet" AS infraspecific_epithet,
       "col:nameReferenceID"      AS name_reference_id,   -- original description
       "col:referenceID"          AS reference_id,        -- supporting reference(s)
       "col:namePublishedInYear"  AS name_published_in_year,
       "col:extinct"              AS extinct,
       "col:kingdom" AS kingdom, "col:phylum" AS phylum, "col:class" AS class,
       "col:order"   AS "order",  "col:family" AS family, "col:genus" AS genus,
       "col:link"                 AS link
FROM read_parquet('col/NameUsage.parquet');
