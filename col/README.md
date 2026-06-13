# Catalogue of Life

The Catalogue of Life [ColDP](https://github.com/CatalogueOfLife/coldp) export
(extended format) converted to Parquet — one file per table. Adapter views are in
`../views.sql` (prefixed `col_`). COL is the lake's **taxonomic backbone**.

## Source

Version 2026-05-15 XR — ChecklistBank dataset `315192`, doi `10.48580/dgxsq`,
"COL26.5 XR". Extended ColDP, downloaded as `export.zip`:

```
https://api.checklistbank.org/dataset/315192/export.zip?extended=true&format=ColDP
```

Unzip into `col/`, then convert from the repo root:

```sh
./col/build_parquet.sh
```

ColDP TSVs are tab-separated with `col:`/`clb:`-prefixed headers; many fields hold
literal double quotes, so the converter parses with `delim='\t', quote='',
all_varchar=true` (all columns VARCHAR for fidelity). It asserts Parquet row count
== raw data-line count per table (both tables verified lossless). Generated
`col/*.parquet` are gitignored.

## Tables (the two we use)

| table | rows | what |
|---|---:|---|
| `NameUsage.tsv` | 7,851,869 | taxa **and** synonyms — the backbone (→ `col_name_usage`) |
| `Reference.tsv` | 2,031,506 | bibliographic references cited by name usages (→ `col_reference`) |

Other ColDP tables (Distribution, VernacularName, TypeMaterial, NameRelation, …)
are present in the export but not yet converted; add them to `TABLES` in
`build_parquet.sh` when needed.

## The col: namespace

Every column is namespaced and the prefix is **not** a reliable type: `col:doi`
is a plain DOI, `clb:merged` is a ChecklistBank merge artefact, and most `col:`
terms are generic CSL/Dublin-Core fields. The `col_*` adapter views map the
columns we use to canonical names (`doi`, `title`, `issued`, `scientific_name`,
…) and drop the prefixes, so queries never touch `col:`. `col_reference.doi` is
lowercased/trimmed so it joins `bhl_doi.doi` and OpenCitations `doi_omid.doi`
directly. See the design note in `../local-data-lake-notes.md`.

## Model & the literature seam

```
col_name_usage (taxon/synonym)
  ├─ parent_id          -> col_name_usage      (classification tree)
  ├─ name_reference_id  -> col_reference        (original description)
  └─ reference_id       -> col_reference        (supporting reference)

col_reference.doi  ──>  bhl_doi.doi            (is the cited work in BHL?)
                   ──>  doi_omid.doi -> citations (OpenCitations impact)
```

## Example queries

```sql
-- How many COL references have a DOI, and how many of those DOIs are in BHL?
SELECT count(*) total, count(doi) with_doi,
       count(DISTINCT CASE WHEN doi IN (SELECT doi FROM bhl_doi) THEN doi END) in_bhl
FROM col_reference;
-- 2,031,506 / 93,877 with DOI / 12,963 distinct DOIs in BHL

-- COL name usages whose original-description paper is held by BHL.
SELECT count(*)
FROM col_name_usage nu
JOIN col_reference r ON r.reference_id = nu.name_reference_id
WHERE r.doi IN (SELECT doi FROM bhl_doi);
-- 94,501
```
