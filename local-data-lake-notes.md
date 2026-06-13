# Building a Local Data Lake for Biodiversity & Bibliographic Data

A working summary of the architecture decisions from this conversation.

## The problem

Tired of endlessly downloading data and crawling APIs. The dream: have BOLD,
Catalogue of Life, parts of GBIF, BHL, OpenCitations, etc. all in one place that
can be queried together — ideally something with BigQuery-like ergonomics, but
local, without converting everything to RDF.

## The core answer: DuckDB + Parquet, as a local data lake

**DuckDB** is an embedded analytical database ("SQLite for analytics") — no
server, just a binary/library. It queries CSV, JSON, and Parquet files directly,
and joins across them (and across SQLite/Postgres/MySQL) **without an ETL load
step first**. That's the BigQuery feel, locally, KISS-friendly.

Store data as **Parquet** (convert from CSV once): far smaller on disk, much
faster to scan, column pruning so queries only read what they touch.

The mechanics of joining are trivial. The genuinely hard part is **shared keys /
identifier reconciliation** — taxonomic names don't match cleanly across BOLD /
COL / GBIF (pick one backbone, e.g. GBIF taxonKey or COL IDs, and map onto it);
literature links via DOI. Budget effort there, not on the engine choice.

On the RDF dream: a graph model is nicer for the *linking* layer, but converting
hundreds of GB of occurrences to RDF and querying at that scale is painful and
most triple stores fall over well before GBIF size. Pragmatic split: bulk data in
Parquet/DuckDB, reserve RDF (or a small link table) for the genuinely
graph-shaped connections.

> PHP caveat: DuckDB's PHP binding is thin (FFI-based). In practice, drive the
> `duckdb` CLI and read back JSON/CSV, or query from Python and expose results.

## Grabbing just parts of GBIF

The AWS Parquet snapshot is a flat set of sharded files (`occurrence.parquet/*`),
**not** partitioned by taxon/country/year — so you can't `aws s3 sync` a subset by
content. Three routes to a subset:

1. **Predicate download** (GBIF filters server-side): filter by taxonKey, country,
   year, etc.; get a Darwin Core Archive or SimpleCSV with a citable DOI. Accepts
   up to 100k search parameters. Path of least resistance.
2. **SQL download** (experimental): select specific columns / summary views, TSV
   output, geospatial helpers like `GBIF_Within(wkt, lat, lng)`. Needs a
   registered GBIF account. Quote SQL-keyword columns: `"year"`, `"month"`.
3. **DuckDB straight against S3** (no account): query the snapshot in place and
   write only the result. But the snapshot isn't partitioned, so a `WHERE` can't
   skip whole files — column projection helps, content filters are a full column
   scan over the network. Fine for one-offs.

```sql
INSTALL httpfs; LOAD httpfs;
SET s3_region = 'eu-central-1';   -- public bucket: anonymous access, no keys

COPY (
  SELECT gbifid, species, specieskey, family,
         decimallatitude, decimallongitude, countrycode, "year"
  FROM read_parquet('s3://gbif-open-data-eu-central-1/occurrence/2026-05-01/occurrence.parquet/*')
  WHERE family = 'Felidae' AND countrycode = 'BR'
) TO 'felidae_br.parquet' (FORMAT PARQUET);
```

**Recommended flow:** pull the subset via route 1 or 2 (clean, citable), then
**re-partition your local copy** Hive-style on the keys you filter on most. After
that, local queries skip irrelevant files. Use route 3 for quick summary stats
where you don't want records at all.

## Hive-style partitioning

A folder-naming convention where partition column *values* are encoded into the
directory path as `key=value`, instead of stored inside the files. Every engine
(DuckDB, Spark, Athena) understands it.

```
occurrence/
  family=Felidae/countrycode=BR/data_0.parquet
  family=Canidae/countrycode=AR/data_0.parquet
```

Two payoffs: the engine reads `family`/`countrycode` as real columns from the
path, and a matching `WHERE` lets it **prune** — skip all non-matching folders
without reading them.

```sql
-- write
COPY (SELECT * FROM my_subset)
TO 'occurrence' (FORMAT PARQUET, PARTITION_BY (family, countrycode));

-- read
SELECT * FROM read_parquet('occurrence/**/*.parquet', hive_partitioning = true);
```

**Gotcha:** partition only on columns you filter on, with sensible cardinality
(`family`, `countrycode`, `year` = good; `species` = thousands of tiny folders =
bad). Lots of small files is its own performance problem.

## The data lake layout: two layers

- **Outer** = one folder per dataset. Not "Hive" — just tidy directory hygiene
  (the data-lake layout).
- **Inner** = `key=value` subfolders *within* a dataset. That's the Hive
  partitioning, applied per table, and only worth it for the big tables.

```
data/
  gbif/                       <- big   -> Hive-partitioned
    family=Felidae/countrycode=BR/part-0.parquet
  opencitations/              <- huge  -> partition (e.g. by year)
    year=2020/part-0.parquet
  col/                        <- small -> just a file
    taxa.parquet
  bold/
    barcodes.parquet
  bhl/
    items.parquet
```

Each dataset is a **table** (a folder of Parquet), not a separate "database."
DuckDB is the single engine over all of them. Partitioning is a within-table
speed trick — cross-dataset joins work regardless.

Make it feel like a real DB with a thin catalog of **views** (a tiny `.duckdb`
pointer file, not a data copy):

```sql
CREATE VIEW gbif AS
  SELECT * FROM read_parquet('data/gbif/**/*.parquet', hive_partitioning = true);
CREATE VIEW col  AS SELECT * FROM read_parquet('data/col/*.parquet');
CREATE VIEW bold AS SELECT * FROM read_parquet('data/bold/*.parquet');
```

## Lake vs lakehouse

This pattern *is* a data lake: storage decoupled from engine, open file format,
schema-on-read, query-in-place. Yours is just local and curated rather than a
sprawling S3 mess — same architecture, concepts transfer if you ever move to S3.

A **lakehouse** adds database guarantees (transactions, schema enforcement,
versioning/time-travel) via table formats like Apache Iceberg or Delta Lake. You
almost certainly don't need it: the sources are periodic bulk snapshots, not live
transactional data, so re-syncing is just "replace the folder." Plain Parquet +
DuckDB views is the deliberately simpler, KISS-correct choice. Promote a single
dataset to a native/Iceberg table only the day you genuinely need versioned,
transactional updates.

## Many small CSVs (and the OpenCitations case)

A folder of same-schema files *is* a table — that's the native shape. DuckDB
globs them:

```sql
SELECT * FROM read_csv('data/thing/*.csv', union_by_name = true);
```

But **keep them as CSV only if you rarely query them.** For repeated use, convert
to Parquet once (kills re-parsing, pins a consistent schema, dodges per-file type
inference drift). If sniffing misbehaves, pass explicit `columns = {...}`.

### OpenCitations Index — the stress test

~2.01 billion citations; 28.1 GB zipped / 179 GB unzipped; ~165 zips × 1000 CSVs
= ~165,000 tiny files. Seven fields per row: `oci, citing, cited, creation,
timespan, journal_sc, author_sc` (OMID-based, highly compressible).

Do **not** query the 165k CSVs in place. Convert **zip by zip** so you never
unzip all 179 GB at once (peak scratch disk ~1 GB):

```bash
mkdir -p parquet
for z in *.zip; do
  tmp=$(mktemp -d)
  unzip -q "$z" -d "$tmp"
  duckdb -c "COPY (SELECT * FROM read_csv('$tmp/*.csv', union_by_name=true))
             TO 'parquet/${z%.zip}.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);"
  rm -rf "$tmp"
done
```

Result: 165 Parquet files (likely near/below the 28 GB zipped size), fast to
scan. (DuckDB reads `.gz`/`.zst` CSVs natively but not multi-file `.zip`, hence
explicit `unzip`.) Optional second pass to partition by publication year:

```sql
COPY (SELECT *, TRY_CAST(substr(creation,1,4) AS INT) AS year
      FROM read_parquet('parquet/*.parquet'))
TO 'data/opencitations' (FORMAT PARQUET, PARTITION_BY (year), COMPRESSION ZSTD);
```

`TRY_CAST` so blank `creation` values don't blow up the run. Expect the one-time
convert to be I/O-bound (tens of minutes to a couple of hours; use an SSD). 2 B
rows is squarely within DuckDB's single-node comfort zone — no cluster needed.

## Schema reconciliation across datasets

**Don't** design one grand canonical schema up front and map everything into it
first — that's the canonical-model death march. Use **conform-as-you-go**, framed
as the medallion pattern:

- **Bronze** — raw, original messy column names, untouched. Source of truth; lets
  you re-run mapping logic without re-downloading.
- **Silver** — reconciliation, done lazily and per-dataset. Map only the dozen
  columns you actually join/filter on, when you need them.
- **Gold** — the small set of curated, joined tables you work against.

The KISS mechanism is **views, not copies** — one "adapter" view per source that
selects and aliases awkward columns into agreed names; raw bytes never move:

```sql
CREATE VIEW gbif AS SELECT
  gbifid           AS occurrence_id,
  scientificname   AS scientific_name,
  decimallatitude  AS lat,
  decimallongitude AS lng,
  "year"           AS event_year
FROM read_parquet('data/gbif/**/*.parquet', hive_partitioning = true);
```

This is what dbt formalizes (staging model per source), but a single
version-controlled `.sql` file of views is the KISS version — and it doubles as
documentation of every mapping decision.

**Highest-leverage move:** adopt an existing standard instead of inventing
canonical names. Map onto **Darwin Core** (`scientificName`, `decimalLatitude`,
`taxonID`, …) for occurrence/taxonomic data — GBIF already interprets to it, so
half the crosswalk is done and the schema is instantly legible to others. For
bibliographic data: CSL-JSON, Dublin Core. Rule: conform to a community
vocabulary if one exists; only invent when nothing fits. (This is the same move
the triple-store dream makes — mapping sources onto a shared ontology — minus the
RDF machinery. A flat crosswalk table `source, source_column, canonical_term,
notes` is the ontology-free version, and can even generate the views.)

**The honest caveat:** column names are the easy 20%. The real work is **values
and meaning** — same name / different meaning, mismatched units, different code
systems (ISO-2 vs ISO-3 country codes), date formats, differing enums, and entity
reconciliation (same species? same paper?). That can't be fully automated and is
where silent bugs live — keep value-level transforms explicit and tested, not
buried in a view. `union_by_name` stacks similar files but does **not** rename or
reconcile.

### Worked example: three sources, one "doi" — and the col: prefix

We now have three bibliographic sources that each carry a DOI, a title, a year,
authors — under three different spellings:

| concept | OpenCitations Meta | BHL | COL (ColDP) |
|---|---|---|---|
| identifier | `omid` / packed `id` | `DOI` (table `doi`) | `col:ID`, `col:doi` |
| title | `title` | `Title` | `col:title` |
| year / date | `pub_date` | `Date` / `Year` | `col:issued`, `col:namePublishedInYear` |
| authors | `author` | `creator` / `partcreator` | `col:author` |

ColDP adds two wrinkles. Every column is namespaced (`col:doi`, `col:title`), and
the prefix is **not** a reliable type: `col:doi` is just a DOI, `clb:merged` is a
ChecklistBank merge artefact, and most `col:` terms are generic CSL / Dublin-Core
fields, not COL-specific. So the prefix can't be stripped blindly to get a clean
name, nor trusted as a meaningful namespace — it has to be mapped explicitly.

The lake's answer is unchanged: a per-source adapter view maps the source
spelling to the canonical name, so queries say `doi`, never `col:doi`. The COL
views (`col_reference`, `col_name_usage`) expose `reference_id`, `doi`, `title`,
`issued`, … and drop the `col:` / `clb:` prefixes; the cross-source question
"COL references that BHL holds" is then just `col_reference.doi = bhl_doi.doi`
(4.6% of COL's 2.03M references carry a DOI; ~13k of those DOIs are in BHL).

What still needs deciding (the open task): the **canonical target vocabulary**
across the whole lake. Bibliographic fields should converge on CSL-JSON / Dublin
Core (`DOI`→`doi`, `container-title`→`container_title`, `issued`→`year`),
taxonomic fields on Darwin Core (`scientificName`, `taxonID`, `taxonRank`, …).
Until that crosswalk is written down (the `source, source_column, canonical_term,
notes` table mentioned above), each adapter view makes the call ad hoc — fine for
now, but the three "doi"s above should all alias to the *same* canonical `doi`,
chosen deliberately rather than per-view.

### In one line

Keep raw untouched; conform lazily through per-source adapter views; borrow an
existing standard (Darwin Core) for the target vocabulary; treat
value/identifier reconciliation as the real project, not the column renaming.
