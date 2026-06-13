# BHL citations vs OpenCitations (exploration)

**Question:** how cited are BHL's articles? Previously answered by hitting the
OpenCitations API once per DOI and stashing results in SQLite. Here we do it
offline against the OpenCitations parquet tables in the lake.

> This is a *precursor*. The intended end state is BHL metadata as its own lake
> dataset, so "BHL citations" becomes a plain `bhl ⋈ opencitations` join (via
> `doi_omid` / `work_stats`) and the export script below is no longer needed.

## Inputs

- `pdoi.txt` — 68,234 BHL part-DOIs (one per line, `10.5962/p.*`).

## Run it

From the **repo root** (parquet paths are relative to it):

```sh
./sandbox/bhl-citations/doi_to_sqlite.sh \
    sandbox/bhl-citations/pdoi.txt \
    sandbox/bhl-citations/bhl_citations.sqlite
```

Builds two tables (`*.sqlite` is gitignored):
- `works` — one row per (doi, omid): title, pub_date, `n_cited_by`, `n_references`
- `citations` — one row per incoming citation: `cited_doi`, `citing_doi`,
  `citing_date`, `timespan`, self-cite flags

~83 k edges in ~90 s (one scan of the 38 GB citations file).

## Findings (2026-06-13 snapshot)

| BHL DOIs | Found in OpenCitations | Cited ≥1× | Total citations | Mean (cited) | Max |
|---:|---:|---:|---:|---:|---:|
| 68,234 | 17,191 (25.2%) | 16,231 | 82,382 | 5.1 | 425 |

- Only ~25% of BHL part-DOIs are in the open citation graph — most BHL content
  predates or sits outside Crossref's open citations. The 17 k that are present
  pull 82 k citations.
- Most-cited: taxonomic monographs and dinosaur osteology (*Succession*; Prosopis
  monographs; *Diplodocus* / *Apatosaurus* osteology).
- Incoming citations rise steadily by citing-work decade, peaking in the 2010s
  (~26 k) and still strong in the 2020s.
- Self-citation negligible (~0.5% journal/author self-cites).

## Gotcha

`doi_omid` is **not unique on DOI** (a DOI can map to several OMID work records
in OpenCitations Meta). Aggregate to DOI level (`GROUP BY doi`, sum `n_cited_by`)
before counting, or impact totals inflate. See `../../opencitations/README.md`.
