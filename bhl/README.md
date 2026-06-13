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

## Citations: BHL ⋈ OpenCitations

A BHL part can carry **two** kinds of DOI: a BHL-minted one (`10.5962/p.*`) and
an **external publisher DOI**. External DOIs have far better coverage in the open
citation graph, so they are the right lens for impact:

| part DOIs | count | in OpenCitations | total citations |
|---|---:|---:|---:|
| BHL-minted `10.5962/p.*` | 68,234 | 25% | 82,382 |
| external publisher | 110,988 | 65% | **2,865,192** |

```sql
-- citation counts per BHL part DOI (view does the doi_omid/work_stats join)
SELECT doi_kind, count(*) part_dois,
       sum(n_cited_by) total_citations
FROM bhl_part_citations
GROUP BY doi_kind;

-- most-cited BHL parts (use external DOIs), with titles
SELECT pc.n_cited_by, p.title, p.container_title, p.date, pc.doi
FROM bhl_part_citations pc
JOIN bhl_part p ON p.part_id = pc.part_id
WHERE pc.doi_kind = 'external'
ORDER BY pc.n_cited_by DESC
LIMIT 20;
```

This supersedes the one-off exporter in `../sandbox/bhl-citations/`.
