-- CD (disruption) index for a single focal paper, against OpenCitations.
--
-- Method: Funk & Owen-Smith (2017). The set-based SQL phrasing follows
-- Sixt & Pasin (2024), "Dimensions: Calculating disruption indices at scale",
-- QSS 5(4), doi:10.1162/qss_a_00328 (see reading/qss_a_00328/). Their elegant
-- trick — score every citation to f as -1 and every citation to f's references
-- as -2, then CD = sum/n + 2 — is algebraically identical to the classic
--
--     CD = (n_i - n_j) / (n_i + n_j + n_k)        in [-1, +1]
--
-- where, among all works citing the focal paper f and/or its references:
--   n_i  cite f but NOT its references      -> disruptive   (+1)
--   n_j  cite f AND its references          -> consolidating (-1)
--   n_k  cite the references but NOT f       -> neutral       (0)
-- +1 = fully disruptive (f eclipses what it built on); -1 = fully consolidating;
-- ~0 = neither. Most papers sit near 0. We report n_i/n_j/n_k explicitly.
--
-- Run from the repo root (needs views.sql for citations / doi_omid /
-- works_by_omid / gbif_download_omid):
--   duckdb lake.duckdb -c ".read views.sql" -c ".read sandbox/disruption-index/cd_index.sql"
-- Uses the sorted edge copies (citations_by_cited / citations_by_citing), so the
-- citer/reference lookups prune instead of full-scanning — a few seconds on a
-- quiet disk. To analyse a different paper, edit focal_doi below.

WITH params AS (
  SELECT lower('10.1098/rspb.2002.2218') AS focal_doi,   -- <- change this
         5 AS t_window                                   -- CD_t window (years)
),
focal_omids AS (
  SELECT DISTINCT omid FROM doi_omid WHERE doi = (SELECT focal_doi FROM params)
),
focal_year AS (
  SELECT min(TRY_CAST(left(pub_date, 4) AS INT)) AS t0
  FROM works_by_omid WHERE omid IN (SELECT omid FROM focal_omids)
),
-- Each lookup hits the sorted copy whose sort key it filters on, so parquet
-- row groups prune instead of full-scanning the 38 GB edge file.
refs AS (  -- works f cites (its predecessors), excluding self  [by citing_omid]
  SELECT DISTINCT cited_omid AS r FROM citations_by_citing
  WHERE citing_omid IN (SELECT omid FROM focal_omids)
    AND cited_omid NOT IN (SELECT omid FROM focal_omids)
),
a AS (     -- distinct citers of f                               [by cited_omid]
  SELECT DISTINCT citing_omid AS c FROM citations_by_cited
  WHERE cited_omid IN (SELECT omid FROM focal_omids)
    AND citing_omid NOT IN (SELECT omid FROM focal_omids)
),
b AS (     -- distinct citers of any reference                   [by cited_omid]
  SELECT DISTINCT citing_omid AS c FROM citations_by_cited
  WHERE cited_omid IN (SELECT r FROM refs)
    AND citing_omid NOT IN (SELECT omid FROM focal_omids)
),
univ AS (  -- the union; flags say which side(s) each citer is on
  SELECT coalesce(a.c, b.c) AS c,
         a.c IS NOT NULL AS cites_f,
         b.c IS NOT NULL AS cites_ref
  FROM a FULL OUTER JOIN b ON a.c = b.c
),
-- One row per citer OMID (works_by_omid is NOT unique on omid; joining raw would
-- multiply rows and inflate the counts).
yr AS (
  SELECT omid, min(TRY_CAST(left(pub_date, 4) AS INT)) AS y
  FROM works_by_omid WHERE omid IN (SELECT c FROM univ) GROUP BY omid
),
enr AS (
  SELECT u.c, u.cites_f, u.cites_ref, yr.y,
         (g.omid IS NOT NULL) AS is_gbif
  FROM univ u
  LEFT JOIN yr ON yr.omid = u.c
  LEFT JOIN gbif_download_omid g ON g.omid = u.c
)
SELECT 'all-time' AS window,
   count(*) FILTER (WHERE cites_f AND NOT cites_ref) AS n_i,
   count(*) FILTER (WHERE cites_f AND cites_ref)     AS n_j,
   count(*) FILTER (WHERE cites_ref AND NOT cites_f) AS n_k,
   count(*) AS n,
   round((count(*) FILTER (WHERE cites_f AND NOT cites_ref)
        - count(*) FILTER (WHERE cites_f AND cites_ref))::DOUBLE
        / nullif(count(*), 0), 4) AS cd
FROM enr
UNION ALL
SELECT 'CD' || (SELECT t_window FROM params) || ' (T+1..T+t)',
   count(*) FILTER (WHERE cites_f AND NOT cites_ref AND y BETWEEN (SELECT t0 FROM focal_year)+1 AND (SELECT t0 FROM focal_year)+(SELECT t_window FROM params)),
   count(*) FILTER (WHERE cites_f AND cites_ref     AND y BETWEEN (SELECT t0 FROM focal_year)+1 AND (SELECT t0 FROM focal_year)+(SELECT t_window FROM params)),
   count(*) FILTER (WHERE cites_ref AND NOT cites_f AND y BETWEEN (SELECT t0 FROM focal_year)+1 AND (SELECT t0 FROM focal_year)+(SELECT t_window FROM params)),
   count(*) FILTER (WHERE y BETWEEN (SELECT t0 FROM focal_year)+1 AND (SELECT t0 FROM focal_year)+(SELECT t_window FROM params)),
   round((count(*) FILTER (WHERE cites_f AND NOT cites_ref AND y BETWEEN (SELECT t0 FROM focal_year)+1 AND (SELECT t0 FROM focal_year)+(SELECT t_window FROM params))
        - count(*) FILTER (WHERE cites_f AND cites_ref     AND y BETWEEN (SELECT t0 FROM focal_year)+1 AND (SELECT t0 FROM focal_year)+(SELECT t_window FROM params)))::DOUBLE
        / nullif(count(*) FILTER (WHERE y BETWEEN (SELECT t0 FROM focal_year)+1 AND (SELECT t0 FROM focal_year)+(SELECT t_window FROM params)), 0), 4)
FROM enr
UNION ALL
SELECT 'all-time, GBIF-excl',
   count(*) FILTER (WHERE cites_f AND NOT cites_ref AND NOT is_gbif),
   count(*) FILTER (WHERE cites_f AND cites_ref     AND NOT is_gbif),
   count(*) FILTER (WHERE cites_ref AND NOT cites_f AND NOT is_gbif),
   count(*) FILTER (WHERE NOT is_gbif),
   round((count(*) FILTER (WHERE cites_f AND NOT cites_ref AND NOT is_gbif)
        - count(*) FILTER (WHERE cites_f AND cites_ref AND NOT is_gbif))::DOUBLE
        / nullif(count(*) FILTER (WHERE NOT is_gbif), 0), 4)
FROM enr;
