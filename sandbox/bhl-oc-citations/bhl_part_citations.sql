-- BHL ⋈ OpenCitations: citation impact of BHL parts via the DOI bridge.
-- Run from the repo root after loading views (duckdb lake.duckdb -c ".read views.sql").
-- This is a worked example, not catalog infrastructure — hence sandbox, not views.sql.

-- A BHL part can carry a BHL-minted DOI (registrant prefix 10.5962/, e.g.
-- 10.5962/p.*, 10.5962/bhl.part.*) AND an external publisher DOI. Classify by
-- the registrant prefix, not a single pattern: anything under 10.5962/ is minted.
CREATE OR REPLACE TEMP VIEW bhl_part_dois AS
SELECT entity_id AS part_id, doi,
       CASE WHEN doi LIKE '10.5962/%' THEN 'bhl_minted' ELSE 'external' END AS doi_kind
FROM bhl_doi
WHERE entity_type = 'Part';

-- Citation count per (part, doi), summed over duplicate OMID records (doi_omid
-- is NOT unique on doi — a DOI can map to several OMID work records, so summing
-- without the GROUP BY inflates totals). One row per part DOI.
CREATE OR REPLACE TEMP VIEW bhl_part_citations AS
SELECT pd.part_id, pd.doi, pd.doi_kind,
       max(CASE WHEN m.omid IS NOT NULL THEN 1 ELSE 0 END) AS in_oc,
       sum(coalesce(s.n_cited_by, 0))::BIGINT AS n_cited_by
FROM bhl_part_dois pd
LEFT JOIN doi_omid   m ON m.doi  = pd.doi
LEFT JOIN work_stats s ON s.omid = m.omid
GROUP BY pd.part_id, pd.doi, pd.doi_kind;

-- Headline: coverage and total citations by DOI kind.
SELECT doi_kind,
       count(*)                       AS part_dois,
       round(100.0 * avg(in_oc), 1)   AS pct_in_oc,
       sum(n_cited_by)                AS total_citations
FROM bhl_part_citations
GROUP BY doi_kind
ORDER BY total_citations DESC;

-- Most-cited BHL parts (external DOIs), with titles.
SELECT pc.n_cited_by, p.title, p.container_title, p.date, pc.doi
FROM bhl_part_citations pc
JOIN bhl_part p ON p.part_id = pc.part_id
WHERE pc.doi_kind = 'external'
ORDER BY pc.n_cited_by DESC
LIMIT 20;

-- =============================================================================
-- Literature-only variant: exclude GBIF occurrence-download citers
-- =============================================================================
-- The counts above use work_stats.n_cited_by, the precomputed in-degree, which
-- includes GBIF occurrence-download DOIs (10.15468/dl.* and cdl.*). GBIF mints a
-- DOI per download that machine-cites every dataset it draws from, so popular
-- datasets accrue tens of thousands of "citations" that aren't literature
-- (e.g. Florabank1, 10.3897/phytokeys.12.2849: ~75k citers, of which only 15
-- are papers). Excluding download citers requires the citing work's identity,
-- so we can't use work_stats — we scan the citation edges and anti-join.

-- Citing works that are GBIF occurrence downloads (both download prefixes) come
-- from the shared gbif_download_omid helper view in views.sql.

-- Literature-only citation count per part DOI. count(DISTINCT citing_omid) also
-- sidesteps the doi_omid-not-unique inflation. Scans the 38 GB citations file
-- (~30-40 s); only parts with >=1 non-GBIF citer appear (INNER JOINs).
CREATE OR REPLACE TEMP VIEW bhl_part_citations_lit AS
SELECT pd.part_id, pd.doi, pd.doi_kind,
       count(DISTINCT c.citing_omid) AS n_cited_by_lit
FROM bhl_part_dois pd
JOIN doi_omid m  ON m.doi = pd.doi
JOIN citations c ON c.cited_omid = m.omid
LEFT JOIN gbif_download_omid g ON g.omid = c.citing_omid
WHERE g.omid IS NULL
GROUP BY pd.part_id, pd.doi, pd.doi_kind;

-- Literature-only headline: parts with >=1 non-GBIF citer, and their citations.
SELECT doi_kind,
       count(*)            AS parts_cited,
       sum(n_cited_by_lit) AS total_lit_citations
FROM bhl_part_citations_lit
GROUP BY doi_kind
ORDER BY total_lit_citations DESC;

-- Most-cited BHL parts, GBIF downloads excluded — the real literature view.
SELECT pc.n_cited_by_lit, p.title, p.container_title, p.date, pc.doi
FROM bhl_part_citations_lit pc
JOIN bhl_part p ON p.part_id = pc.part_id
WHERE pc.doi_kind = 'external'
ORDER BY pc.n_cited_by_lit DESC
LIMIT 20;
