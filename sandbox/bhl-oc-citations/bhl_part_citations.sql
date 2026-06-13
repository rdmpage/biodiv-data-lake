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
