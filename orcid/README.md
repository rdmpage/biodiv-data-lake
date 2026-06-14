# ORCID

The ORCID public-data-file **summaries** (one XML record per researcher)
converted to two Parquet tables. Adapter views are in `../views.sql` (prefixed
`orcid_`). ORCID is the lake's **author / researcher backbone**: it links people
to their works (via DOI) and affiliations.

## Source

Data from ORCID [public data file](https://info.orcid.org/documentation/integration-guide/working-with-bulk-data/) for 2025 which is [CC0 1.0 Public Domain Dedication](https://creativecommons.org/publicdomain/zero/1.0/). 

- ORCID, . (2025). ORCID Public Data File 2025 (Version 1). ORCID. https://doi.org/10.23640/07243.30375589.v1

- File: `ORCID_2025_10_summaries.tar.gz` (~46 GB), figshare file `58834837`
  (`https://orcid.figshare.com/ndownloader/files/58834837`).
- Release: ORCID 2025-10 public data file, **summaries** subset (record summaries
  only — identity + activity *summaries*; not the full activities file).
- Download quirk: fetch via `https://ndownloader.figshare.com/files/58834837`
  (it 302-redirects to a short-lived presigned S3 URL; the URL supports HTTP
  ranges so the download resumes with `curl -C -`).

## Build

```sh
./orcid/build_parquet.sh        # from the repo root: download + parse + Parquet
```

ColDP-style fidelity rules apply: stream the tar (never extract 20M+ tiny files),
parse XML with the stdlib (`tarfile` + `xml.etree`), parse with no quoting and
**sanitize whitespace** (ORCID name/title fields contain literal tabs/newlines).
The parse is single-threaded over ~20M records — expect a few hours. Generated
`orcid/*.tsv` and `orcid/*.parquet` are gitignored. Prototype: `../sandbox/orcid-explore/`.

## Tables (views in `../views.sql`)

| view | grain | rows | columns |
|---|---|---:|---|
| `orcid_person` | one row per researcher | 26,078,951 | `orcid, given_name, family_name, credit_name, country, n_employments, n_works, n_work_dois, full_name` |
| `orcid_work` | one row per (researcher, work DOI) | 117,458,062 | `orcid, doi, title, work_type` |
| `orcid_name` | one row per (orcid, name_type, name) | 25,937,127 | `orcid, name_type, name` — for **name → ORCID** lookup |

`orcid_work.doi` is lowercased so it joins `doi_omid.doi` (OpenCitations),
`bhl_doi.doi`, and `col_reference.doi`. `orcid_name` unions the `primary`
(given + family) and `credit` name forms; see caveats on `other-names`.

## Model & the seam

```
orcid_person (researcher)
  └─ orcid ──< orcid_work (orcid, doi)
                       │
        orcid_work.doi ──> doi_omid.doi -> citations   (OpenCitations: impact, CD, co-citation)
                       ──> bhl_doi.doi                  (work held by BHL — rare)
                       ──> col_reference.doi            (work is a COL reference — rare)
```

The strong link is **ORCID → OpenCitations**. Full-file coverage:

| metric | value |
|---|--:|
| researchers | 26,078,951 |
| …with ≥1 work DOI | 6,596,014 (25.3%) |
| distinct work DOIs | 46,174,106 |
| **…in OpenCitations** | **38,823,763 (84.1%)** |
| …in BHL | 23,676 |
| …in COL references | 30,404 |

So ~38.8M works link authors → citations (author-level impact, co-authorship,
per-author disruption). BHL/COL overlap is tiny (ORCID is modern/general; those
are legacy/taxonomic).

## Example queries

```sql
-- person by ORCID
SELECT * FROM orcid_person WHERE orcid = '0000-0001-5099-6000';

-- works by ORCID
SELECT doi, work_type, title FROM orcid_work WHERE orcid = '0000-0001-5099-6000';

-- ORCID by name (use ILIKE — names embed titles like "Dr."; returns candidates)
SELECT orcid, name_type, name FROM orcid_name WHERE name ILIKE '%Debashis Bhowmick%';

-- an author's works ranked by citations
SELECT w.doi, s.n_cited_by, w.title
FROM orcid_work w
JOIN doi_omid m   ON m.doi = w.doi
JOIN work_stats s ON s.omid = m.omid
WHERE w.orcid = '0000-0001-5099-6000'
ORDER BY s.n_cited_by DESC;
```

## Notes / caveats

- Summaries carry *activity summaries* only — work titles, types, and external
  ids (incl. DOI) — not full work metadata (that's the separate activities file).
- A work appears once per contributing ORCID, so the same DOI recurs across
  co-authors; `count(DISTINCT doi)` when measuring distinct works.
- ~25% of records have any work DOI; many profiles are sparse (country is unset
  for the large majority).
- **Name lookup is fuzzy.** Names embed titles ("Dr. ..."), vary in case/order,
  and `name → ORCID` is heavily many-to-one (e.g. ~3,033 ORCIDs named "Wei Wang")
  — that ambiguity is why ORCID exists. Treat a name match as *candidates* and
  disambiguate by works/affiliation; use `ILIKE`.
- **`other-names` not captured.** ORCID's person `other-names` (variant names) are
  in the schema but were 0/77,554 in the early-ORCID sample we checked, so the
  parser skips them. Add them (a third `name_type`) via a re-parse if name recall
  needs it.
