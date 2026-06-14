# ROR (Research Organization Registry)

[ROR](https://ror.org) converted to Parquet — the lake's **organisation
backbone**. A ROR ID is a shared identifier (used in ORCID affiliations, Crossref
funders, DataCite, Wikidata, …), so ROR is the spine to disambiguate the
free-text affiliations we get from ORCID and Zenodo creators. Adapter view `ror`
is in `../views.sql`.

## Source

<!-- @rpage: add dump version/date notes if useful. -->

- ROR data dump on Zenodo, community `ror-data`: record **20512981** = **v2.8**
  (`v2.8-2026-06-02-ror-data.zip`), CC0. The zip holds both JSON and CSV; we use
  the CSV.
- **Download manually** — Zenodo rate-limits bulk/agent traffic (a big download
  earns a 403 "unusual traffic" block), so `build_parquet.sh` does not fetch it.
  Drop the zip in `ror/` and run the script.

## Build

```sh
./ror/build_parquet.sh        # extracts the CSV from ror/v*-ror-data.zip -> ror/ror.parquet
```

ROR v2 CSV is RFC-4180 (comma-delimited, **double-quoted** — fields may contain
commas/newlines, unlike our tab/`quote=''` sources), columns dot-flattened,
multi-valued fields `;`-separated. Loaded all-VARCHAR; the view casts.

## Table (view in `../views.sql`)

`ror` — one row per organisation (127,138; 124,575 active):

| column | notes |
|---|---|
| `ror_id` | bare id, e.g. `039zvsn29` |
| `ror_url` | full `https://ror.org/...` |
| `name`, `acronym`, `aliases` | `aliases` is `;`-separated |
| `types` | `;`-separated, e.g. `education; funder` |
| `status` | active / inactive / withdrawn |
| `established` | year (INT) |
| `country_code`, `country_name`, `lat`, `lng` | primary location (GeoNames) |
| `grid_id`, `isni_id`, `wikidata_id`, `fundref_id` | external-id crosswalks (preferred) |
| `website`, `wikipedia` | links |

## The seam (future)

`ror_id` is the join key once we capture organisation IDs from other sources:
ORCID employment/education affiliations and Zenodo creators currently give
**free-text** `affiliation` only (no ROR ID in what we parsed), so the link is
name-based for now. Capturing ROR IDs from ORCID's `disambiguated-organization`
elements (a re-parse) would make it an exact join — researcher → organisation.

```sql
-- example: org lookup by name
SELECT ror_id, name, country_code, types FROM ror
WHERE name ILIKE '%Natural History Museum%' AND country_code = 'GB';
```

## Caveats

- Multi-valued fields (`aliases`, `types`, and the external-id `.all` columns not
  exposed here) are `;`-separated strings, not arrays.
- Affiliations elsewhere in the lake are free text; no exact ROR join yet (above).
