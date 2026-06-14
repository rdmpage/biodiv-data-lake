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

## Notes

- Anchored on the BOLD dataset↔publication pairing; `work_doi` joins everything
  in the lake (`crossref_*`, `doi_omid`, `orcid_person` via authors, `ofr`/`ror`
  via funders).
- `data_doi` (the BOLD dataset) is a DataCite DOI — present in `datacite_doi`.
