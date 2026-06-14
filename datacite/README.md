# DataCite 

> The DataCite Public Data File contains metadata records in JSON format for all DataCite DOIs in Findable state that were registered up to the end of 2025.

## Source

DataCite Public Data File 2025 https://doi.org/10.14454/t5qb-d995. You need to request access via email to a link that expires within 24 hours, agree to the [DataCite Data File Use Policy](https://support.datacite.org/docs/datacite-data-file-use-policy) which declares that the data is available under a [CC0](https://creativecommons.org/publicdomain/zero/1.0/) waiver.

A 32 GB `.tar` that expands to ~615 GB. We extract **only the DOI list** (the
per-month CSVs), not the metadata. The tar layout is
`dois/updated_YYYY-MM/<month>.csv.gz` (DOI list: `doi,state,client_id,updated`)
plus `part_*.jsonl.gz` (the metadata, which we never read).

## Build

```sh
./datacite/build_parquet.sh        # extract csv.gz members -> datacite_doi.parquet
```

`extract_dois.py` opens the tar random-access and reads **only the `*.csv.gz`
members** (so it touches their bytes + a header scan, not the 615 GB of JSONL),
adding `source` = the `updated_YYYY-MM` folder. View `datacite_doi` is in
`../views.sql`. The tar, `*.tsv`, and `*.parquet` are gitignored.

## Table (view in `../views.sql`)

`datacite_doi` — one row per DOI (**115,732,777**; 108.5M findable):

| column | notes |
|---|---|
| `doi` | lowercased; joins `doi_omid` / `bhl_doi` / `col_reference` / `zenodo_record` / `crossref_*` |
| `state` | `findable` / `registered` |
| `client_id` | the data centre (e.g. BOLD, Zenodo) — index of "who minted it" |
| `updated` | last-updated timestamp |
| `source` | `updated_YYYY-MM` folder → where to find this DOI's JSONL for on-demand metadata |

## Uses

DataCite's API caps at 10k results and its bibliographic metadata is patchy, so a
full DOI index is the way to ask "what's in DataCite". Examples:

```sql
SELECT count(*) FROM datacite_doi WHERE doi LIKE '10.5883/bold%';  -- BOLD BINs: 144,497
SELECT count(*) FROM datacite_doi WHERE doi LIKE '10.5883/ds%';    -- BOLD datasets: 2,620
SELECT client_id, count(*) n FROM datacite_doi GROUP BY 1 ORDER BY n DESC LIMIT 20;
```

For the metadata of selected DOIs later, scan the JSONL in the matching `source`
folder of the tar (the lake equivalent of the per-DOI metadata lookup).

## Caveats

- DOI index only — no titles/authors/etc. (that's the JSONL, fetched on demand).
- Vintage: registered up to end of 2025, so 2026 DOIs (e.g. recent Zenodo
  records) aren't here yet.


