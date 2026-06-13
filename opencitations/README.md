# OpenCitations in the biodiversity data lake

Two Parquet tables built from OpenCitations dumps, queryable with DuckDB.

| File | What | Rows | Size |
|------|------|------|------|
| `opencitations.parquet` | Citations (OpenCitations Index) | 2,315,872,191 | 38 GB |
| `opencitations_meta.parquet` | Works metadata (OpenCitations Meta) | 122,191,271 | 11 GB |

Built 2026-06-12. DuckDB v1.4.2.

---

## How they were generated

### 1. Citations — `opencitations.parquet`

- **Source:** 165 zip files from figshare, downloaded by `figsharefiles.sh`
  (ids listed in the script; one figshare file id per `<id>.zip`).
  The downloader uses `curl -fL -C - --retry ...` in parallel (`xargs -P`),
  so it resumes partial files and retries failures. Re-runnable.
- **Build:** `build_parquet.sh` — for each zip it extracts the many CSVs inside,
  writes a `parts/<id>.parquet`, deletes the temp CSVs, then merges all parts into
  one `opencitations.parquet` (zstd-compressed). Resumable (skips existing parts).
- **Columns** (all VARCHAR for fidelity):
  `id, citing, cited, creation, timespan, journal_sc, author_sc`
  - `citing`, `cited` are bare OMIDs, e.g. `omid:br/0617078761`
  - `creation` is a (possibly partial) date like `1999-03`
  - `timespan` is an ISO-8601 duration like `P41Y` (gap between cited and citing work)
  - `journal_sc` / `author_sc` = journal / author self-citation (`yes`/`no`)

### 2. Works metadata — `opencitations_meta.parquet`

- **Source:** `output_csv_2026_01_14.tar.gz` (kept in this folder) — 40,732 CSVs.
- **Build:** `build_meta_parquet.sh` — extracts the tarball, then one DuckDB COPY
  over the whole CSV glob into `opencitations_meta.parquet` (zstd).
- **Columns** (all VARCHAR):
  `id, title, author, issue, volume, venue, page, pub_date, type, publisher, editor`
  - `id` is a **space-separated list** of identifiers, OMID first, e.g.
    `omid:br/0690942028 openalex:W1998836856 doi:10.1016/j.ajog.2011.08.004 pmid:21963310`
  - `author` is `Name [omid:ra/...]; Name [omid:ra/...]` (semicolon-separated)
  - `venue` embeds journal ids: `Applied Optics [omid:br/065012051 issn:2155-3165 ...]`

### The join key

Citations reference works by **bare OMID**; Meta stores the OMID as the **first
token** of `id`. So:

```sql
... JOIN read_parquet('opencitations_meta.parquet') m
      ON c.cited = split_part(m.id, ' ', 1)
```

DOIs in Meta are stored **lowercase** and prefixed `doi:` inside `id`. Match with
`id LIKE '%doi:10.xxxx/...%'` (lowercase the DOI first).

---

## Performance note

These Parquet files have no indexes, so a query that filters on `citing`/`cited`
or searches `id` **full-scans** the file — expect **~1 minute** for a citation
lookup that also joins titles. That's normal. To make repeated exploration
snappier, consider loading into a native DuckDB database once:

```sql
-- run once: duckdb lake.duckdb
CREATE TABLE citations AS SELECT * FROM read_parquet('opencitations.parquet');
CREATE TABLE meta      AS SELECT * FROM read_parquet('opencitations_meta.parquet');
-- optional helper: pre-extract the OMID so joins/filters skip split_part()
ALTER TABLE meta ADD COLUMN omid VARCHAR;
UPDATE meta SET omid = split_part(id, ' ', 1);
```

Then query `citations` / `meta` directly in `lake.duckdb`.

---

## Example queries

Run any of these with `duckdb -c "..."` from this folder (or paste into a
`duckdb` session). They read the Parquet files directly.

### Quick row counts

```sql
SELECT count(*) FROM read_parquet('opencitations.parquet');       -- citations
SELECT count(*) FROM read_parquet('opencitations_meta.parquet');  -- works
```

### Given a DOI: what it cites, and what cites it (counts)

```sql
WITH work AS (
  SELECT split_part(id,' ',1) AS omid
  FROM read_parquet('opencitations_meta.parquet')
  WHERE id LIKE '%doi:10.1016/j.ajog.2011.08.004%'
  LIMIT 1
)
SELECT
  (SELECT omid FROM work) AS omid,
  (SELECT count(*) FROM read_parquet('opencitations.parquet')
     WHERE citing = (SELECT omid FROM work)) AS references_out,  -- it cites
  (SELECT count(*) FROM read_parquet('opencitations.parquet')
     WHERE cited  = (SELECT omid FROM work)) AS cited_by;        -- cites it
```

### Given a DOI: list the works it CITES (its reference list), with titles

```sql
WITH work AS (
  SELECT split_part(id,' ',1) AS omid
  FROM read_parquet('opencitations_meta.parquet')
  WHERE id LIKE '%doi:10.1016/j.ajog.2011.08.004%' LIMIT 1
)
SELECT m.title, m.pub_date, split_part(m.id,' ',1) AS cited_omid
FROM read_parquet('opencitations.parquet') c
JOIN read_parquet('opencitations_meta.parquet') m
  ON c.cited = split_part(m.id,' ',1)
WHERE c.citing = (SELECT omid FROM work)
ORDER BY m.pub_date;
```

### Given a DOI: list the works that CITE it (its citers), with titles

```sql
WITH work AS (
  SELECT split_part(id,' ',1) AS omid
  FROM read_parquet('opencitations_meta.parquet')
  WHERE id LIKE '%doi:10.1016/j.ajog.2011.08.004%' LIMIT 1
)
SELECT m.title, m.pub_date, split_part(m.id,' ',1) AS citing_omid
FROM read_parquet('opencitations.parquet') c
JOIN read_parquet('opencitations_meta.parquet') m
  ON c.citing = split_part(m.id,' ',1)
WHERE c.cited = (SELECT omid FROM work)
ORDER BY m.pub_date DESC;
```

To pull the citing/cited works' DOIs too, extract them from `m.id` with
`regexp_extract(m.id, 'doi:(\S+)', 1)`.

### Look up a work's full metadata by DOI

```sql
SELECT * FROM read_parquet('opencitations_meta.parquet')
WHERE id LIKE '%doi:10.1016/j.ajog.2011.08.004%';
```

### Citations created per year (trend)

```sql
SELECT left(creation, 4) AS year, count(*) AS n
FROM read_parquet('opencitations.parquet')
WHERE creation IS NOT NULL AND length(creation) >= 4
GROUP BY year ORDER BY year;
```

### Most-cited works overall (heavy — full scan + group; minutes)

```sql
SELECT cited, count(*) AS times_cited
FROM read_parquet('opencitations.parquet')
GROUP BY cited
ORDER BY times_cited DESC
LIMIT 20;
-- then join the top OMIDs back to meta for titles
```

### Self-citation rate

```sql
SELECT author_sc, count(*) AS n
FROM read_parquet('opencitations.parquet')
GROUP BY author_sc;
```

---

## Files in this folder

- `opencitations.parquet`, `opencitations_meta.parquet` — the data lake tables
- `output_csv_2026_01_14.tar.gz` — raw Meta source (kept for rebuilds)
- `figsharefiles.sh` — citation zip downloader (re-downloadable source)
- `build_parquet.sh` — citations → Parquet
- `build_meta_parquet.sh` — Meta → Parquet
- `*.log`, `figsharefiles.txt`, `figsharefiles.sh.bak` — build logs / scratch

The figshare zips, `parts/`, and the extracted Meta CSVs were deleted after the
Parquet files were verified; all are reproducible from the scripts and the
`.tar.gz`.
