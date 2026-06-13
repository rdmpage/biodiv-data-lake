# ORCID summaries — sample exploration

Quick look at what's in the ORCID public-data-file **summaries** and how well it
joins the lake — from a *sample*, not the full 43 GB. Exploratory; promote to a
real `orcid/` dataset (full download + adapter views) if it earns its place.

## Source & download gotcha

`ORCID_2025_10_summaries.tar.gz`, 46.3 GB, figshare file `58834837`
(`https://orcid.figshare.com/ndownloader/files/58834837`). One XML per researcher
under `ORCID_2025_10_summaries/<bucket>/<orcid-id>.xml` (~20M+ records).

- Download via `https://ndownloader.figshare.com/files/58834837` (it 302-redirects
  to a short-lived presigned S3 URL — always re-hit the ndownloader URL; it
  supports HTTP ranges, so `curl -C -` resumes).
- The generic `api.figshare.com/v2/file/download/<id>` endpoint 302s to the same
  place. (Same figshare family as the OpenCitations downloader.)

## What we did

Streamed the first ~150 MB of the tarball (a truncated prefix) and parsed the
first **50,000** records with `parse_summaries.py` (stdlib only — `tarfile` +
`xml.etree`, no lxml/pyarrow). It emits two TSVs → Parquet:

- `orcid_person`: `orcid, given, family, credit, country, n_emp, n_work, n_doi`
- `orcid_work`: `orcid, doi, title, type` (one row per work DOI)

```sh
# from sandbox/orcid-explore/ (sample.tar.gz already fetched via a ranged curl)
python3 parse_summaries.py sample.tar.gz orcid 50000
```

Two parsing lessons baked into the script: parse with no quoting and **sanitize
whitespace** — ORCID name fields can contain literal tabs/newlines
(e.g. `"MIRTHA\tYUNI"`) that otherwise corrupt the TSV.

## Findings (50k-record sample)

| metric | value |
|---|--:|
| persons | 50,000 |
| with ≥1 work | 13,863 (28%) |
| with ≥1 work DOI | 13,049 (26%) |
| distinct work DOIs | 188,080 |
| **…in OpenCitations** | **166,979 (89%)** |
| …in BHL | 76 |
| …in COL references | 163 |

- **The seam is ORCID → OpenCitations.** ~89% of ORCID work DOIs resolve into the
  open citation graph, so ORCID gives author → DOI links and OpenCitations gives
  the citations: author-level impact, co-authorship, disruption-by-author, etc.
- **BHL/COL overlap is tiny** (76 / 163) — ORCID skews modern and general; BHL and
  COL are legacy / taxonomic literature. ORCID is not the bridge to those.
- Most-cited ORCID-linked works are landmarks (human genome, the 2020 COVID
  coronavirus paper, 1000 Genomes, GBD, graphene oxide, IoT survey).
- **Country is mostly empty** (44.5k of 50k NULL); where present, BR > CN > IN > US.

## Caveats

- **Not a random sample.** These are the first 50k records in tar order, i.e. the
  lowest ORCID iDs (early adopters). Coverage/affiliation stats are indicative,
  not population estimates — a real ingest should parse the whole file.
- Summaries hold *activity summaries* only (work titles, types, external-ids like
  DOI), not full work metadata; that's the separate, much larger activities file.

## Scaling to a full dataset (deferred)

Download the full 43 GB to `orcid/`, run `parse_summaries.py` over the whole tar
with no cap (streaming, so no millions-of-files extraction), write
`orcid/orcid_person.parquet` + `orcid/orcid_work.parquet`, and add `orcid_*`
adapter views in `../../views.sql` (canonical `doi` to join `doi_omid`). Then
ORCID becomes the author backbone for the lake.
