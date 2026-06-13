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

### Caveat: GBIF downloads dominate the head of the list

The naive most-cited list is topped by Pensoft data papers (PhytoKeys, ZooKeys,
Biodiversity Data Journal) with citation counts in the tens of thousands. These
aren't literature citations — they're **GBIF occurrence-download** events. GBIF
mints a DOI (`10.15468/dl.*`, and custom downloads `10.15468/cdl.*`) for every
download and machine-cites the datasets it draws from, so a widely-used dataset
accrues huge "citation" counts.

The clearest case is *Florabank1* (`10.3897/phytokeys.12.2849`, 75,135 cites):

| citer kind | distinct citing DOIs |
|---|---:|
| GBIF occurrence downloads (`10.15468/{dl,cdl}.*`) | 75,120 |
| scholarly literature | **15** |

### Literature-only variant (GBIF downloads excluded)

`work_stats.n_cited_by` (the precomputed in-degree) can't be filtered by citer,
so the literature-only view scans the citation edges and anti-joins out
download citers — the `gbif_download_omid` helper view in `../../views.sql`
(`bhl_part_citations_lit` in the SQL; ~30-40 s):

| part DOIs (>=1 lit citer) | count | literature citations |
|---|---:|---:|
| external publisher | 58,700 | **561,510** |
| BHL-minted (`10.5962/*`) | 24,442 | 132,984 |

Excluding downloads cuts external citations from 2.81M → 562k, and the most-cited
list becomes genuine biodiversity literature — e.g. Grinnell's 1917 *The
Niche-Relationships of the California Thrasher*, Chagas' 1909 description of
*Schizotrypanum cruzi*, GeoCAT, and the APG ordinal classification of flowering
plants — instead of download artifacts.

> Note: this treats GBIF downloads as non-literature *citers* only. They remain
> in the graph as cited works too; a stricter analysis would also drop
> `10.15468/%` from the cited side.

## Gotcha

`doi_omid` is **not unique on DOI** (a DOI can map to several OMID work records
in OpenCitations Meta). Aggregate to DOI level (`GROUP BY doi`, sum `n_cited_by`)
before counting, or impact totals inflate. See `../../opencitations/README.md`.
