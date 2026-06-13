# biodiv-data-lake

Experiments with a local biodiversity & bibliographic **data lake**: keep big
public datasets (OpenCitations, GBIF, Catalogue of Life, BOLD, BHL, …) as
Parquet on local disk and query them — and join across them — with **DuckDB**,
without standing up a server or converting everything to RDF.

The architecture rationale (why DuckDB + Parquet, Hive partitioning, the
medallion/views approach to schema reconciliation) is written up in
[`local-data-lake-notes.md`](local-data-lake-notes.md). This README tracks
**where we are and what's next**.

## Approach in one paragraph

Storage is decoupled from the engine: each dataset is a folder of Parquet files
(schema-on-read, query-in-place). A thin, version-controlled catalog of **views**
([`views.sql`](views.sql)) maps the raw, messy column names into clean canonical
ones — so you query `works.doi`, not a regex over a packed identifier string.
Raw data is never mutated (Bronze); views do lazy per-source reconciliation
(Silver); a small set of curated/precomputed tables can be materialised when a
query is too slow to run live (Gold).

## Repo layout

```
biodiv-data-lake/
├── README.md                  <- you are here
├── local-data-lake-notes.md   <- architecture decisions / design notes
├── views.sql                  <- adapter views (the lake "catalog")
├── lake.duckdb                <- DuckDB catalog file (gitignored; rebuild from views.sql)
└── opencitations/             <- first dataset (see opencitations/README.md)
    ├── README.md              <- how the Parquet was built + example queries
    ├── figsharefiles.sh       <- parallel downloader for the 165 Index zips
    ├── figsharefiles.txt      <- source file-id list
    ├── build_parquet.sh       <- Index zips  -> opencitations.parquet
    └── build_meta_parquet.sh  <- Meta tarball -> opencitations_meta.parquet
```

Large data files (`*.parquet`, `*.tar.gz`, `*.zip`, `lake.duckdb`, logs) are
**gitignored** — they live in the working tree but are too big for GitHub and are
fully reproducible from the scripts above.

## Status

| Dataset | State | Notes |
|---------|-------|-------|
| **OpenCitations Index** (citations) | ✅ ingested | `opencitations/opencitations.parquet` — 2,315,872,191 rows, 38 GB |
| **OpenCitations Meta** (works) | ✅ ingested | `opencitations/opencitations_meta.parquet` — 122,191,271 rows, 11 GB |
| Adapter views | ✅ `works`, `citations`, `citations_resolved` | clean columns incl. first-class `doi`/`omid` |
| Catalogue of Life | ⬜ source identified | ColDP export (see Sources) |
| GBIF | ⬜ planned | predicate/SQL download, then re-partition Hive-style |
| BOLD, BHL | ⬜ planned | |

## Querying the lake

Always run DuckDB **from the repo root** (view paths are relative). The catalog
view definitions live in `views.sql`; (re)load them into `lake.duckdb` with:

```sh
cd /Volumes/Acer/biodiv-data-lake
duckdb lake.duckdb -c ".read views.sql"   # rebuild views any time
duckdb lake.duckdb                         # interactive session
```

Example — the headline OpenCitations query, *how many times has a DOI been
cited*, expressed naturally against the adapter views:

```sql
SELECT w.doi, count(*) AS times_cited
FROM works w
JOIN citations c ON c.cited_omid = w.omid
WHERE w.doi = '10.1016/j.ajog.2011.08.004'   -- DOIs stored lowercase
GROUP BY w.doi;
```

More examples (reference list / citers with titles, per-year trends,
most-cited works) are in [`opencitations/README.md`](opencitations/README.md).

## Where we're going (next)

1. **Faster DOI queries for OpenCitations.** The query above full-scans the 38 GB
   citations file (~20 s). Decide whether to add a **Gold** layer (precomputed
   per-work `n_cited_by` / `n_references` table) for ~1–3 s lookups, or keep it
   pure-views (KISS). *(Open design question — revisit next.)*
2. **Bring in a taxonomic backbone** (GBIF taxonKey or COL IDs) as the reconciliation
   spine, then add occurrence/taxonomic datasets and map their columns onto
   **Darwin Core** via adapter views.
3. **Cross-dataset joins** — e.g. link literature (DOI) to taxa/occurrences.

## Sources

- **OpenCitations Meta** — https://download.opencitations.net/#meta
  (dump DOI: https://doi.org/10.5281/zenodo.18324537)
- **OpenCitations Index** — https://download.opencitations.net/#index
  (https://doi.org/10.6084/m9.figshare.24356626). Bulk download doesn't work; it's
  165 individual files. The `https://figshare.com/ndownloader/files/(\d+)` URLs fail
  with curl, but `https://api.figshare.com/v2/file/download/\d+` works
  (HT https://stackoverflow.com/a/75511393). See `opencitations/figsharefiles.sh`.
- **Catalogue of Life** — https://www.catalogueoflife.org/data/download
  (`curl -L 'https://api.checklistbank.org/dataset/315192/export.zip?extended=true&format=ColDP' > export.zip`)
