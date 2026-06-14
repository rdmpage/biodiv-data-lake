# Open Funder Registry (OFR)

> The Open Funder Registry (OFR, formerly FundRef) and associated funding metadata allows everyone to have transparency into research funding and its outcomes. It’s an open and unique registry of persistent identifiers for grant-giving organisations around the world. [CrossRef](https://www.crossref.org/services/funder-registry/)

## Source 

Latest version 1.65 [CC0 licensed](https://creativecommons.org/choose/zero/), available as RDF from [GitLab](https://gitlab.com/crossref/open_funder_registry).

The funder backbone, alongside ROR (organisations). Each funder is a FundRef
DOI; the bare id crosswalks to `ror.fundref_id`, and the full DOI is what
Crossref records use as a funder identifier. Adapter view `ofr_funder` is in
`../views.sql`.

## Build

`registry.rdf` is a single ~90 MB RDF/XML SKOS document. Drop it in `ofr/` and
run from the repo root:

```sh
./ofr/build_parquet.sh        # parse_registry.py -> ofr_funder.tsv -> ofr_funder.parquet
```

Stdlib parser (`parse_registry.py`, `xml.etree.iterparse`, streamed). Generated
`ofr/*.tsv` and `ofr/*.parquet` are gitignored (reproducible from `registry.rdf`).

## Table (view in `../views.sql`)

`ofr_funder` — one row per funder (45,700):

| column | notes |
|---|---|
| `fundref_id` | bare FundRef number, e.g. `100000001` — joins `ror.fundref_id` |
| `funder_doi` | full `10.13039/<id>` — the form Crossref uses as a funder identifier |
| `name`, `aliases` | `aliases` is `;`-separated (alt labels) |
| `country`, `region` | FundRef's own codes (e.g. country `usa`) |
| `body_type`, `body_subtype` | e.g. `gov` / `National government` |
| `tax_id`, `status` | status set for deprecated/renamed funders |
| `broader_id` | parent funder (bare id) — the SKOS hierarchy |
| `created`, `modified` | timestamps |

## The seams

- **OFR ⋈ ROR** — `ofr_funder.fundref_id = ror.fundref_id` (9,556 funders are in
  ROR); gives a funder both its ROR org record and ROR's other crosswalks.
- **funder DOI** — `funder_doi` (`10.13039/*`) matches the funder identifier used
  in Crossref funding metadata, for when that's brought in.
- **hierarchy** — `broader_id` chains funders (e.g. an institute → its agency).

## Caveats

- Two id forms on purpose — join on whichever a source uses (`fundref_id` bare vs
  `funder_doi`); SQL picks.
- `country`/`region`/`body_type` use FundRef's own vocabularies, not ISO.
- Deprecated/renamed funders carry `status`; their `svf:renamedAs` /
  `incorporatedInto` redirect targets are not yet captured.

