# Crossref

Crossref bibliographic metadata, fetched **on demand per DOI via the REST API**
(not the 208 GB public data file). The point isn't to mirror Crossref — it's to
**enrich the DOIs the lake already cares about** with the fields OpenCitations
lacks: **funders** (→ `ofr_funder` / `ror` via `funder_doi`/`fundref_id`),
**author ORCIDs** (→ `orcid_person`), and **reference lists**. Adapter views
`crossref_*` are in `../views.sql`.

## Workflow

```sh
# 1. fetch (caches each work as crossref/cache/<prefix>/<doi>.json; idempotent)
CROSSREF_MAILTO=you@example.org php crossref/fetch.php <doi-list.txt> [more.txt ...]
# 2. build Parquet from the whole cache
./crossref/build_parquet.sh
```

`fetch.php` hits `api.crossref.org/works/{doi}` (polite pool via `CROSSREF_MAILTO`),
unwraps the `message` envelope, and caches just the work. `build.php` flattens the
cache into four TSVs → Parquet. Both are safe to re-run.

## Providing a list of DOIs

A **plain text file, one DOI per line** (bare DOIs or `doi.org/…` URLs; blank
lines and `#` comments ignored). Pass one or more files. The natural source is
**the lake itself** — generate the target list with a query. For example, the
Plazi treatment → journal-article DOIs that aren't yet in OpenCitations (the
highest-value gap to fill):

```sh
duckdb lake.duckdb -c ".read views.sql" -c "
COPY (
  SELECT DISTINCT rel.doi
  FROM zenodo_record r JOIN zenodo_related rel ON rel.zenodo_id = r.zenodo_id
  WHERE r.resource_subtype='Taxonomic treatment'
    AND rel.relation='IsPartOf' AND rel.id_type='DOI'
    AND rel.doi NOT IN (SELECT doi FROM doi_omid)
) TO 'crossref/want.txt' (HEADER false);"
php crossref/fetch.php crossref/want.txt
```

Keep several lists if handy (`bold.txt`, `zenodo-articles.txt`, …) and pass them all.

## Adding more DOIs over time

The **cache is the source of truth** and `fetch.php` is **idempotent** — it skips
any DOI already cached. So adding more is just: append to a list (or regenerate
the lake-driven list, or add another file) and re-run `fetch.php` — only the new
DOIs hit the API. Then re-run `build_parquet.sh` (it rebuilds from the entire
cache, so new records appear). To refresh stale records (Crossref updates over
time) use `php crossref/fetch.php --force <list>`. `failed.txt` logs not-found
(e.g. DataCite-only DOIs such as Zenodo) and transient errors for retry.

## Tables (views in `../views.sql`)

| view | grain | key columns |
|---|---|---|
| `crossref_work` | one per DOI | `doi, type, title, container_title, publisher, issn, year, crossref_cited_by, n_authors, n_references, n_funders, license, url, abstract` |
| `crossref_author` | one per (DOI, author) | `doi, seq, given, family, orcid, affiliation` |
| `crossref_funder` | one per (DOI, funder) | `doi, funder_doi, fundref_id, name, awards` |
| `crossref_reference` | one per cited reference | `doi, key, cited_doi, unstructured` |
| `crossref_relation` | one per typed relation | `doi, relation_type, target_type, target` |

## The seams

- `crossref_author.orcid` → `orcid_person` (people).
- `crossref_funder.funder_doi` → `ofr_funder.funder_doi`; `fundref_id` → `ror.fundref_id` (funders/orgs).
- `crossref_work.doi` / `crossref_reference.cited_doi` → `doi_omid` (cross-check / fill OpenCitations).
- `crossref_work.doi` ← `zenodo_related` `IsPartOf` (the article behind a treatment).
- `crossref_relation` — typed work↔work edges (`has-preprint`/`is-preprint-of`,
  `is-supplement-to`, `is-version-of`, …); links **preprints ↔ final papers**
  (valuable when the published version is paywalled), supplements, and versions.

## Caveats

- The API wraps the work in a `message` envelope — `fetch.php` unwraps it.
- DataCite-registered DOIs (incl. Zenodo `10.5281/…`) 404 here → `failed.txt`.
- ORCID resolution is limited by the loaded ORCID dump's vintage (2025-10); ORCIDs
  newer than the dump won't resolve in `orcid_person` yet.
- `abstract` may carry JATS/HTML markup; whitespace is collapsed for TSV safety.
- Reference lists vary in completeness per publisher; many refs lack a DOI.
