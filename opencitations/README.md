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

- `opencitations.parquet`, `opencitations_meta.parquet` — the core data tables
- `work_stats.parquet`, `doi_omid.parquet` — precomputed helpers (see below)
- `output_csv_2026_01_14.tar.gz` — raw Meta source (kept for rebuilds)
- `figsharefiles.sh`, `figsharefiles.txt` — citation zip downloader + id list
- `build_parquet.sh` — citations → Parquet
- `build_meta_parquet.sh` — Meta → Parquet
- `build_stats.sql` — builds `work_stats.parquet` + `doi_omid.parquet`
- `*.log` — build logs

The figshare zips, `parts/`, and the extracted Meta CSVs were deleted after the
Parquet files were verified; all are reproducible from the scripts and the
`.tar.gz`. The adapter views and macros live in `../views.sql`.

---

## Use-case patterns (via the catalog)

Run these from the **repo root** after loading the catalog
(`duckdb lake.duckdb -c ".read views.sql"`). They use the views/macros
(`works`, `citations`, `doi_omid`, `work_stats`, `cites()`, `cited_by()`,
`citation_count()`) instead of raw `read_parquet`.

### 1. Casual — one DOI

```sql
-- Single-record lookup, ~55 ms (sorted works copies, row-group pruned):
SELECT * FROM work_by_doi('10.1093/database/bau061');
SELECT * FROM work_by_omid('omid:br/06301504805');

-- Instant citation count (reads work_stats, no big scan):
SELECT citation_count('10.1093/database/bau061');

-- The actual citers / reference list (scans citations, ~20 s):
SELECT * FROM cited_by('10.1093/database/bau061');   -- who cites it
SELECT * FROM cites('10.1093/database/bau061');      -- what it cites

-- "Related" works by co-citation (scans citations, ~25-30 s):
SELECT * FROM related('10.1093/database/bau061') LIMIT 15;
```

DOIs are matched lowercase; the macros lowercase their argument for you.

### 2. Batch metrics — impact of a set of DOIs (e.g. BHL)

Load your DOIs into a table (lowercased), then join to the precomputed stats —
a hash join over small tables, not a 2.3 B-row scan, so all ~68 k BHL DOIs run
in ~5 s.

> **Gotcha — `doi_omid` is NOT unique on `doi`.** ~1.9 M DOIs map to >1 OMID
> (OpenCitations Meta has duplicate work records, up to 11 per DOI). A plain
> `LEFT JOIN` fans those rows out and over-counts. **Always aggregate to DOI level
> first** (`GROUP BY doi`, summing `n_cited_by` across the duplicate OMID records —
> citations are split between them in the Index, so summing recovers the true total).

```sql
-- e.g. CREATE TABLE bhl_dois AS
--   SELECT DISTINCT lower(trim(column0)) AS doi
--   FROM read_csv('pdoi.txt', header=false, columns={'column0':'VARCHAR'});

-- per-DOI citation counts (DOI-level; 0 for absent / never cited)
SELECT b.doi, sum(coalesce(s.n_cited_by, 0))::BIGINT AS times_cited
FROM bhl_dois b
LEFT JOIN doi_omid m   ON m.doi  = b.doi
LEFT JOIN work_stats s ON s.omid = m.omid
GROUP BY b.doi
ORDER BY times_cited DESC;

-- aggregate impact (dedup to DOI level before counting)
WITH per_doi AS (
  SELECT b.doi,
         bool_or(m.omid IS NOT NULL)           AS found,
         sum(coalesce(s.n_cited_by, 0))        AS cited_by
  FROM bhl_dois b
  LEFT JOIN doi_omid m   ON m.doi  = b.doi
  LEFT JOIN work_stats s ON s.omid = m.omid
  GROUP BY b.doi
)
SELECT count(*)                          AS dois,
       count(*) FILTER (WHERE found)     AS matched_in_opencitations,
       sum(cited_by)::BIGINT             AS total_citations
FROM per_doi;
```

### 3. Citation-graph queries

The OMID `citations` edge list is the graph substrate; resolve to DOIs at the
ends as needed. These are heavier (self-joins / scans) — fine for a focal set,
expensive across the whole corpus.

**Co-citation** — works most often cited *together with* a focal work (papers
that share citers are topically related). Wrapped as the `related()` macro:

```sql
SELECT co_citations, doi, title FROM related('10.1093/database/bau061') LIMIT 25;
```

The macro (see `../views.sql`) finds the focal work's citers, then counts the
other works those citers also cite — a self-join over the `citations` edges, so
~25-30 s until we build a sorted citations copy. For **bibliographic coupling**
(works that share *references* rather than citers), swap the join: match on
`a.citing_omid = b.citing_omid` over reference sets instead.

**Disruption / CD index** (Funk & Owen-Smith; an SQL formulation exists for
BigQuery). For a focal paper F: classify each work that cites F by whether it
*also* cites F's references — type i (cites F only) is "disruptive", type j
(cites both) is "consolidating", type k (cites refs only, not F). CD ≈
(n_i − n_j) / (n_i + n_j + n_k). All computable from `citations` for a focal set;
best run per-paper or for a modest batch rather than corpus-wide. *(Template to
be added once we pick the focal-set workflow.)*

> Performance note: graph queries and `cited_by()`/`cites()` scan the 38 GB
> citations file. If these become a routine workload we can add a citations copy
> **sorted by `cited_omid`** so DuckDB prunes row groups on lookups (turning ~20 s
> scans into sub-second seeks) — see the repo README roadmap.
