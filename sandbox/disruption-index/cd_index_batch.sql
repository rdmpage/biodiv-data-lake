-- CD (disruption) index for SEVERAL focal papers in one pass (2 scans total,
-- vs 2 scans per paper). Same method as cd_index.sql; see that file + README for
-- the definition and Sixt & Pasin (2024) reference. Run from the repo root:
--   duckdb lake.duckdb -c ".read views.sql" -c ".read sandbox/disruption-index/cd_index_batch.sql"
--
-- Include a paper with a known CD as a correctness anchor (here the barcoding
-- paper, CD_all = 0.2367). Edit the VALUES list to choose papers.
-- Once the sorted citation copies exist (opencitations/build_citations_sorted.sql),
-- the two scans below prune to sub-second.

WITH dois(doi) AS (VALUES
  ('10.1098/rspb.2002.2218'),            -- barcoding (anchor)
  ('10.1371/journal.pone.0066213'),      -- BIN system
  ('10.1111/j.1471-8286.2007.01678.x'),  -- BOLD data system
  ('10.1093/molbev/mst010'),             -- MAFFT v7 (software)
  ('10.1093/bioinformatics/btu033') ),   -- RAxML v8 (software)
focal AS (SELECT DISTINCT d.doi, m.omid FROM dois d JOIN doi_omid m ON m.doi=d.doi),
fyear AS (SELECT f.doi, min(TRY_CAST(left(w.pub_date,4) AS INT)) t0
          FROM focal f LEFT JOIN works_by_omid w ON w.omid=f.omid GROUP BY f.doi),
focal_omids AS (SELECT DISTINCT omid FROM focal),
-- references of each focal (out-edges -> citations_by_citing); the redundant
-- WHERE IN lets the sorted copy prune, the JOIN attributes back to the focal doi.
refs AS (SELECT DISTINCT f.doi, c.cited_omid AS r
         FROM citations_by_citing c JOIN focal f ON f.omid = c.citing_omid
         WHERE c.citing_omid IN (SELECT omid FROM focal_omids)
           AND c.cited_omid NOT IN (SELECT omid FROM focal_omids)),
-- citers of each focal (in-edges -> citations_by_cited)
amap AS (SELECT DISTINCT f.doi, c.citing_omid AS c
         FROM citations_by_cited c JOIN focal f ON f.omid = c.cited_omid
         WHERE c.cited_omid IN (SELECT omid FROM focal_omids)
           AND c.citing_omid NOT IN (SELECT omid FROM focal_omids)),
all_refs AS (SELECT DISTINCT r FROM refs),
-- citers of any reference, attributed back to each focal paper (by cited_omid)
refciters AS (SELECT c.citing_omid AS c, c.cited_omid AS r
              FROM citations_by_cited c WHERE c.cited_omid IN (SELECT r FROM all_refs)),
bmap AS (SELECT DISTINCT rf.doi, rc.c FROM refciters rc JOIN refs rf ON rf.r=rc.r
         WHERE rc.c NOT IN (SELECT omid FROM focal_omids)),
univ AS (SELECT coalesce(a.doi,b.doi) doi, coalesce(a.c,b.c) c,
                a.c IS NOT NULL cites_f, b.c IS NOT NULL cites_ref
         FROM amap a FULL OUTER JOIN bmap b ON a.doi=b.doi AND a.c=b.c),
yr AS (SELECT omid, min(TRY_CAST(left(pub_date,4) AS INT)) y FROM works_by_omid
       WHERE omid IN (SELECT c FROM univ) GROUP BY omid),
enr AS (SELECT u.doi,u.cites_f,u.cites_ref,yr.y FROM univ u LEFT JOIN yr ON yr.omid=u.c)
SELECT e.doi,
  count(*) FILTER (WHERE cites_f AND NOT cites_ref) n_i,
  count(*) FILTER (WHERE cites_f AND cites_ref) n_j,
  count(*) FILTER (WHERE cites_ref AND NOT cites_f) n_k,
  round((count(*) FILTER (WHERE cites_f AND NOT cites_ref)-count(*) FILTER (WHERE cites_f AND cites_ref))::DOUBLE/nullif(count(*),0),4) cd_all,
  round((count(*) FILTER (WHERE cites_f AND NOT cites_ref AND e.y BETWEEN fy.t0+1 AND fy.t0+5)-count(*) FILTER (WHERE cites_f AND cites_ref AND e.y BETWEEN fy.t0+1 AND fy.t0+5))::DOUBLE/nullif(count(*) FILTER (WHERE e.y BETWEEN fy.t0+1 AND fy.t0+5),0),4) cd5
FROM enr e JOIN fyear fy ON fy.doi=e.doi
GROUP BY e.doi ORDER BY cd_all DESC;
