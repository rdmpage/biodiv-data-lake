# Zenodo

The Zenodo metadata dump (OAI-DataCite XML), parsed to normalised Parquet and
**filtered to biodiversity communities**. Adapter views are in `../views.sql`
(prefixed `zenodo_`). Of interest because Zenodo hosts Plazi **taxonomic
treatments**, their figures, and small taxonomic **journals** — each a record
that links to people (ORCID), literature (DOI → OpenCitations), and taxa.

## Source

Source is https://developers.zenodo.org/#metadata-dumps version `839f6c8b-29d0-438e-b8c9-602200a28bac`, created `2026-06-07T04:01:23.756140+00:00`, the current version is available from https://zenodo.org/api/exporter.

- Dump: `https://zenodo.org/api/exporter/records-xml.tar.gz`
  (see https://developers.zenodo.org/#list-available-dumps). One `<id>.xml` per
  record, OAI-DataCite envelope (`<oai_datacite><payload><resource>…`).
- **Generated stream — no Content-Length, no Range/resume.** Download is one shot
  (`--retry` restarts on failure). The whole dump is kept on disk so other
  communities can be re-filtered later without re-downloading.

## Filter

We keep only records whose `IsPartOf` community URL is **`biosyslit`** or
**`bionomia`** — the Plazi + Bionomia slices. Relevant records exist outside
these (small taxonomic journals with thin metadata), but there's no clean way to
catch them yet; they remain in the on-disk dump for later. A byte-substring
pre-filter skips non-matching records before any XML parse, so the run only
parses the target slice.

## Build

```sh
./zenodo/build_parquet.sh                      # download + parse + Parquet
ZENODO_COMMUNITIES=biosyslit ./zenodo/build_parquet.sh   # override communities
```

Stdlib parser (`parse_records.py`): `tarfile` + `xml.etree`, parsed by local tag
name (namespaces ignored), `quote=''` + whitespace-collapsed fields for TSV
fidelity. `doi` is lowercased so it joins `doi_omid` / `bhl_doi` / `col_reference`.

## Tables (views in `../views.sql`)

| view | grain | key columns |
|---|---|---|
| `zenodo_record` | one per record | `zenodo_id, doi, doi_is_zenodo, version_of, resource_type, resource_subtype, title, date, year, publisher, license, open_access, community, issn, plazi_lsid` |
| `zenodo_creator` | one per (record, creator) | `zenodo_id, seq, name, given, family, orcid, affiliation` |
| `zenodo_related` | one per related identifier | `zenodo_id, relation, id_type, resource_type, value, doi` |
| `zenodo_subject` | one per (record, subject) | `zenodo_id, subject` |
| `zenodo_description` | one per description | `zenodo_id, description_type, text` (Abstract / Other) |

`resource_subtype` distinguishes treatments (`resource_type='Text'`,
`resource_subtype='Taxonomic treatment'`). For treatments the `Abstract`
description is the full treatment text (diagnosis, type material, coordinates).

## Model & the seams

```
zenodo_record (treatment / article / figure / dataset)
  ├─ zenodo_id ──< zenodo_creator (orcid) ──> orcid_person          (people)
  ├─ doi ───────────────────────────────────> doi_omid -> citations (impact)
  ├─ zenodo_id ──< zenodo_related
  │      IsPartOf DOI (the journal article) ─> doi_omid -> citations
  │      IsPartOf ISSN / URL community, HasPart/Cites figures, IsVersionOf
  │      IsSourceOf URL ─────────────────────> GBIF species / ChecklistBank taxon
  ├─ zenodo_id ──< zenodo_subject  (taxonomic keywords) ~~> COL names
  └─ zenodo_id ──< zenodo_description (full treatment text; coordinates)
```

## Example queries

```sql
-- treatments and the journal article each is part of (-> OpenCitations)
SELECT r.zenodo_id, r.title, rel.doi AS article_doi
FROM zenodo_record r
JOIN zenodo_related rel ON rel.zenodo_id = r.zenodo_id
WHERE r.resource_subtype = 'Taxonomic treatment'
  AND rel.relation = 'IsPartOf' AND rel.id_type = 'DOI'
LIMIT 20;

-- Zenodo creators that resolve to an ORCID record in the lake
SELECT count(DISTINCT c.orcid) FROM zenodo_creator c
JOIN orcid_person p ON p.orcid = c.orcid WHERE c.orcid <> '';
```

## Caveats

- Community-filtered (biosyslit/bionomia) — not all of Zenodo.
- Description text has newlines/tabs **collapsed to single spaces** for TSV
  safety; structure (paragraphs) is lost — re-parse from the dump if needed.
- A record can list multiple communities; `zenodo_record.community` is `;`-joined.
- DOIs are usually `10.5281/zenodo.*` (`doi_is_zenodo`); some records carry an
  external DOI instead.
