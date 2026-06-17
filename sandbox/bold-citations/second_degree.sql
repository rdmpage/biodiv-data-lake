-- Second-degree harvest: DOIs of papers that cite the papers that cite BOLD
-- datasets — one hop out from the work_doi set in datadoi_cites_workdoi.tsv.
--
-- Path: first-degree work_doi -> doi_omid (OMID) -> citations_by_cited (in-edges,
-- "who cites X") -> citing works -> doi_omid (keep only citers that have a DOI),
-- anti-joining gbif_download_omid to drop GBIF download machine-citations (which
-- otherwise dominate the in-edges to these papers). ~46 s.
--
-- Run from the lake root:
--   duckdb lake.duckdb -c ".read views.sql" -c ".read sandbox/bold-citations/second_degree.sql"
--
-- Writes two files alongside this recipe:
--   workdoi_citedby_workdoi.tsv  edges (first_degree_doi, second_degree_doi) — provenance
--   second_degree_dois.txt       distinct second-degree DOIs, one per line, for crossref/fetch.php

CREATE OR REPLACE TEMP TABLE second_degree_edges AS
WITH work_dois AS (
  SELECT DISTINCT lower(work_doi) AS doi
  FROM read_csv('sandbox/bold-citations/datadoi_cites_workdoi.tsv', delim='\t', header=true)
),
first_degree AS (                          -- first-degree DOI <-> its OMID
  SELECT m.doi AS first_degree_doi, m.omid AS cited_omid
  FROM work_dois w JOIN doi_omid m ON m.doi = w.doi
),
edges AS (                                 -- who cites each first-degree work
  SELECT f.first_degree_doi, c.citing_omid
  FROM first_degree f
  JOIN citations_by_cited c ON c.cited_omid = f.cited_omid
)
SELECT DISTINCT e.first_degree_doi, dm.doi AS second_degree_doi
FROM edges e
JOIN doi_omid dm               ON dm.omid = e.citing_omid   -- only citers with a DOI
LEFT JOIN gbif_download_omid g ON g.omid  = e.citing_omid
WHERE g.omid IS NULL                                        -- drop GBIF downloads
ORDER BY 1, 2;

COPY second_degree_edges
  TO 'sandbox/bold-citations/workdoi_citedby_workdoi.tsv' (FORMAT CSV, DELIMITER '\t', HEADER);

COPY (SELECT DISTINCT second_degree_doi FROM second_degree_edges ORDER BY 1)
  TO 'sandbox/bold-citations/second_degree_dois.txt' (FORMAT CSV, HEADER false);
