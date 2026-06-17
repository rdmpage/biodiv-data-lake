# BOLD dataset citations (Crossref enrichment example)

Who cites BOLD datasets, and what can we say about the **funding, authorship, and
organisations** behind those papers — by enriching the citing publications with
Crossref (→ OFR/ROR/ORCID). A worked example of the `crossref/` on-demand layer.

## Source

`datadoi_cites_workdoi.tsv` — pairs of **BOLD dataset DOI** (`data_doi`,
`10.5883/ds-*`) and the **publication DOI that cites it** (`work_doi`). 1,657
pairs: 1,430 distinct citing publications across 1,513 distinct BOLD datasets.
This is the source of truth for "papers citing BOLD datasets" (versioned here so
the example is reproducible).

## Reproduce

```sh
# 1. fetch Crossref metadata for the citing publications
duckdb -csv -noheader -c "
  SELECT DISTINCT lower(work_doi) FROM read_csv('sandbox/bold-citations/datadoi_cites_workdoi.tsv', delim='\t', header=true)
" > sandbox/bold-citations/work_dois.txt
CROSSREF_MAILTO=you@example.org php crossref/fetch.php sandbox/bold-citations/work_dois.txt
./crossref/build_parquet.sh
# 2. run the queries below (duckdb lake.duckdb -c ".read views.sql" -c "...")
```

Coverage: 1,393 of 1,430 citing pubs have Crossref metadata (~97%); the rest are
non-Crossref DOIs / not found.

## Findings

**Top funders** (Crossref `funder` → `ofr_funder` name, `ror` country):
NSERC Canada (32 papers), Research Council of Finland (29), German research
ministry (27), Czech Science Foundation (26), NSF (24)… Canadian funders dominate
(NSERC, Genome Canada, Ontario, Canada First) — fitting, as BOLD/iBOL is Guelph-based.

**Top authors** (`crossref_author.orcid` → `orcid_person`): Peter Huemer (36),
M. Alex Smith (32), Sonia Ferreira (20), Daniel Janzen (19), … Paul Hebert (16).

**Preprints** (`crossref_relation`): 57 of the citing papers have a `has-preprint`
link to a preprint (bioRxiv `10.1101/*`, ARPHA, Research Square) — useful when the
published version is paywalled.

```sql
-- top funders of papers citing BOLD datasets
WITH pairs AS (SELECT DISTINCT lower(work_doi) AS doi
               FROM read_csv('sandbox/bold-citations/datadoi_cites_workdoi.tsv', delim='\t', header=true))
SELECT coalesce(o.name, f.name) AS funder, r.country_code, count(DISTINCT f.doi) papers
FROM crossref_funder f JOIN pairs USING (doi)
LEFT JOIN ofr_funder o ON o.fundref_id = f.fundref_id
LEFT JOIN ror r        ON r.fundref_id = f.fundref_id
GROUP BY 1,2 ORDER BY papers DESC LIMIT 15;

-- citing papers that have a preprint
SELECT rel.doi AS published, rel.target AS preprint
FROM crossref_relation rel
JOIN (SELECT DISTINCT lower(work_doi) doi FROM read_csv('sandbox/bold-citations/datadoi_cites_workdoi.tsv', delim='\t', header=true)) p USING (doi)
WHERE rel.relation_type = 'has-preprint';
```

## Second-degree harvest (papers citing the BOLD-citing papers)

One hop further out: the DOIs of papers that **cite** the 1,430 BOLD-citing
publications. This grows the worked example from ~1.4k DOIs to ~14k, all reachable
through OpenCitations without leaving the lake.

`second_degree.sql` walks the citation graph: first-degree `work_doi` → `doi_omid`
→ `citations_by_cited` (in-edges, "who cites X") → citing works → back to `doi_omid`,
anti-joining `gbif_download_omid` to strip GBIF download machine-citations (which
otherwise dominate the in-edges — ~26k of the ~37k raw citers).

```sh
# 1. harvest the second-degree DOIs (~46 s)
duckdb lake.duckdb -c ".read views.sql" -c ".read sandbox/bold-citations/second_degree.sql"
# -> workdoi_citedby_workdoi.tsv (provenance edges) + second_degree_dois.txt (DOI list)

# 2. enrich them with Crossref (skips DOIs already cached from the first-degree set)
CROSSREF_MAILTO=you@example.org php crossref/fetch.php sandbox/bold-citations/second_degree_dois.txt
./crossref/build_parquet.sh
```

Yield: **14,099 distinct second-degree DOIs** across 22,664 provenance edges (a
paper can cite several BOLD-citing papers), from 1,209 first-degree papers that
have real (non-GBIF, DOI-bearing) citers. 1,345 of the 1,430 first-degree DOIs
(94%) are in OpenCitations; the rest aren't indexed there.

`workdoi_citedby_workdoi.tsv` keeps the `(first_degree_doi, second_degree_doi)`
provenance, so you can always trace a harvested DOI back to which BOLD-citing
paper(s) it cites.

## Notes

- Anchored on the BOLD dataset↔publication pairing; `work_doi` joins everything
  in the lake (`crossref_*`, `doi_omid`, `orcid_person` via authors, `ofr`/`ror`
  via funders).
- `data_doi` (the BOLD dataset) is a DataCite DOI — present in `datacite_doi`.
- The second-degree harvest (`second_degree.sql`) is regenerable from the lake;
  `datadoi_cites_workdoi.tsv` remains the versioned source of truth for hop 1.
