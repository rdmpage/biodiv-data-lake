# BHL (Biodiversity Heritage Library)

The BHL Open Data relational export (https://registry.opendata.aws/bhl-open-data/)
converted to Parquet — one file per table. Adapter views are in `../views.sql`
(prefixed `bhl_`).

## Source

Tab-separated, gzipped, UTF-8 (with BOM) dumps, one per BHL database table,
mounted locally from AWS. Convert with:

```sh
BHL_SRC="/path/to/BHL AWS.localized/data" ./bhl/build_parquet.sh   # from repo root
```

Fields have no embedded tabs/newlines (parsed row counts match line counts), so
the converter reads them with `delim='\t', quote='', all_varchar=true` — all
columns kept as VARCHAR for fidelity. Generated `bhl/*.parquet` are gitignored.

## Tables

| table | rows | what |
|---|---:|---|
| `title` | 192,039 | journals / books (bibliographic title) |
| `item` | 324,356 | scanned volumes (→ title) |
| `part` | 404,793 | **articles / segments** — the citable units (→ item) |
| `doi` | 303,701 | polymorphic DOI bridge: `EntityType` Part / Title |
| `creator`, `partcreator` | 381k / 555k | authors (title- and part-level) |
| `partpage` | 4,678,333 | part ↔ page mapping |
| `*identifier`, `subject` | — | external ids, subjects |
| `page` | 68,657,888 | page metadata (no OCR text) |
| `pagename` | 216,874,371 | taxonomic names found on pages (`NameConfirmed`) |

Built 2026-06-13 (BHL export dated 2026-06-06). DuckDB v1.4.2. ~2.4 GB Parquet.

## Model

```
title ──< item ──< part
                    │
        doi (EntityType='Part'|'Title', EntityID) ── the DOI bridge
        part ──< partpage >── page ──< pagename   (names layer)
```

## DOIs

The `doi` table is a polymorphic bridge: `EntityType` is `Part` or `Title`,
`EntityID` points at the corresponding row. A given entity can carry both a
**BHL-minted** DOI (registrant prefix `10.5962/`, in patterns `10.5962/p.*`,
`10.5962/t.*`, `10.5962/bhl.part.*`, `10.5962/bhl.title.*`) and an **external
publisher** DOI. External DOIs have far better coverage in the open citation
graph, so they are the better lens for citation impact.

Worked example — joining BHL part DOIs to OpenCitations citation counts (via
`doi_omid` / `work_stats`) — lives in
[`../sandbox/bhl-oc-citations/`](../sandbox/bhl-oc-citations/).
