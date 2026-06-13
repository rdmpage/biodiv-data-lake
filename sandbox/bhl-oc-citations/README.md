# BHL ⋈ OpenCitations (in-lake join)

**Question:** how cited are BHL's articles? Now that BHL is in the lake as its
own dataset, this is a plain `bhl ⋈ opencitations` join — BHL part DOIs →
`doi_omid` → `work_stats.n_cited_by` — with no export step. This realises the
end state anticipated by the SQLite precursor in `../bhl-citations/`.

Kept in `sandbox/` (not as catalog views) because it's a worked example of
*using* the lake, not core infrastructure. Eventually a curated version may be
promoted into the user-facing examples.

## Run it

From the **repo root** (view paths are relative):

```sh
duckdb lake.duckdb -c ".read views.sql" \
                   -c ".read sandbox/bhl-oc-citations/bhl_part_citations.sql"
```

## DOI kinds

A BHL part can carry a **BHL-minted** DOI and/or an **external publisher** DOI.
BHL-minted DOIs all sit under the `10.5962/` registrant prefix but in several
patterns — classifying on a single pattern (`10.5962/p.*`) misses most of them:

| pattern | entity | count |
|---|---|---:|
| `10.5962/bhl.title.*` | Title | 123,117 |
| `10.5962/p.*` | Part | 68,234 |
| `10.5962/bhl.part.*` | Part | 12,609 |
| `10.5962/t.*` | Title | 491 |
| external publisher | Part | 98,379 |
| external publisher | Title | 871 |

So the robust rule is **prefix, not pattern**: `doi LIKE '10.5962/%'` ⇒
`bhl_minted`, else `external`.

## Findings (2026-06-13 snapshot, part DOIs)

| part DOIs | count | in OpenCitations | total citations |
|---|---:|---:|---:|
| BHL-minted (`10.5962/*`) | 80,843 | 31.6% | 137,651 |
| external publisher | 98,379 | 64.8% | **2,809,923** |

- External DOIs have far better coverage in the open citation graph (65% vs 32%)
  and carry the overwhelming majority of citations — they're the right lens for
  impact.
- Earlier numbers in `../bhl-citations/` (68,234 minted / 82,382 cites; 110,988
  external / 2,865,192 cites) were skewed by the single-pattern classifier, which
  filed the 12,609 `10.5962/bhl.part.*` DOIs as external.

### Caveat on the "most-cited" list

The top external parts are Pensoft data papers (PhytoKeys, ZooKeys, Biodiversity
Data Journal) with citation counts in the tens of thousands (e.g. *Florabank1*,
75 k). Those are dataset/occurrence citations, not classic article citations, so
they dominate the head of the distribution. Filter by container/journal if you
want a literature-only view.

## Gotcha

`doi_omid` is **not unique on DOI** (a DOI can map to several OMID work records
in OpenCitations Meta). Aggregate to DOI level (`GROUP BY doi`, sum `n_cited_by`)
before counting, or impact totals inflate. See `../../opencitations/README.md`.
