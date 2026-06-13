# Disruption (CD) index for a single paper

Computing the **CD index** (Funk & Owen-Smith 2017) for one focal paper against
the OpenCitations graph in the lake, using the set-based SQL phrasing from
Sixt & Pasin (2024), *Dimensions: Calculating disruption indices at scale*,
QSS 5(4), [doi:10.1162/qss_a_00328](https://doi.org/10.1162/qss_a_00328) — the
paper in [`../../reading/qss_a_00328/`](../../reading/qss_a_00328/). They write
it for Dimensions on BigQuery; here it's adapted to DuckDB + OpenCitations.

This is a per-paper probe, not a corpus-wide computation (the lake has no sorted
citations copy yet, so each run is two ~20 s scans of the 38 GB edge file).

## The measure

Among all works that cite the focal paper *f* and/or its references:

| class | cites *f* | cites *f*'s refs | meaning | score |
|---|---|---|---|---|
| nᵢ | yes | no | builds on *f*, ignores what *f* built on → **disruptive** | +1 |
| nⱼ | yes | yes | cites *f* alongside its predecessors → **consolidating** | −1 |
| nₖ | no | yes | same topic as *f* but ignores *f* | 0 |

**CD = (nᵢ − nⱼ) / (nᵢ + nⱼ + nₖ)**, in [−1, +1]. +1 fully disruptive, −1 fully
consolidating, ~0 neither (where most papers sit). Sixt & Pasin's score-everything
−1/−2 trick (`sum/n + 2`) is algebraically the same thing; verified below.

## Focal paper

`10.1098/rspb.2002.2218` — Hebert, Cywinska, Ball & deWaard (2003),
*Biological Identifications Through DNA Barcodes*, Proc. R. Soc. B.
`omid:br/06203438101`, published 2003-02-07. In OpenCitations: **10,144 citers**,
**34 references** recorded.

## Result

```
window                n_i    n_j    n_k      n      CD
all-time             8466   1678  18533  28677  +0.2367
CD5 (2004–2008)       412    154   5072   5638  +0.0458
all-time, GBIF-excl  8405   1678  18533  28616  +0.2351
```

Cross-check via Sixt & Pasin's formula: (−|A| − 2|B|)/n + 2 =
(−10144 − 2·20212)/28678 + 2 = **+0.2367** ✓ (|A| = citers of *f* = 10,144;
|B| = citers of refs = 20,212).

### Reading it

- **All-time CD ≈ +0.24 — clearly disruptive.** Most papers cluster near 0, so a
  sustained positive quarter-point is a strong disruptive signal. It fits the
  history: the barcoding paper founded a research program (COI as a universal
  species identifier) that subsequent work cites *as the origin point* without
  reaching back to its predecessors. nᵢ (8,466, cite *f* only) dwarfs nⱼ (1,678,
  cite *f* with its refs) by ~5:1.
- **CD₅ ≈ +0.05 — almost neutral in the first 5 years.** Disruptiveness here is a
  *long-run* property. Early on, the large, foundational references (general
  molecular-systematics methods) are still being co-cited and independently cited
  (nₖ = 5,072 dominates the 2004–2008 window), so the short-window index is flat.
  The disruptive signal accumulates as "DNA barcoding" becomes its own citing
  community over the following decade. This is the well-known window sensitivity
  of the CD index — CD₅ and all-time can tell different stories.
- **GBIF downloads are negligible here** (61 of 8,466 nᵢ citers; CD 0.2367 →
  0.2351). Unlike data papers such as Florabank1, a 2003 methods paper isn't
  machine-cited by GBIF occurrence downloads — so the `gbif_download_omid` scrub
  barely moves it. Included as a variant for consistency with the lake's other
  citation analyses.

### Example disruptive (nᵢ) citers, 2004

Papers citing Hebert 2003 but none of its references — taxonomy / molecular-ID
work invoking it as the founding reference:
*Exploring Prokaryotic Taxonomy*; *Molecular Taxonomy and Population Structure of
a Culicoides Midge Vector*; *galaxie — CGI Scripts for Sequence Identification
Through Automated Phylogenetic Analysis*; *Modernizando a Taxonomia*.

## Comparison across papers

Run via `cd_index_batch.sql` (all papers in one 2-scan pass; barcoding paper
included as a correctness anchor — reproduces +0.2367). Sorted by CD:

| paper | refs | nᵢ | nⱼ | nₖ | CD (all) | CD₅ |
|---|--:|--:|--:|--:|--:|--:|
| RAxML v8 (`10.1093/bioinformatics/btu033`) | 15 | 24,439 | 3,330 | 36,317 | +0.329 | +0.302 |
| Barcoding (`10.1098/rspb.2002.2218`) | 34 | 8,464 | 1,678 | 18,533 | +0.237 | +0.046 |
| MAFFT v7 (`10.1093/molbev/mst010`) | 49 | 32,121 | 4,507 | 117,390 | +0.179 | +0.142 |
| BOLD data system (`10.1111/j.1471-8286.2007.01678.x`) | 24 | 3,435 | 1,897 | 128,351 | +0.012 | −0.005 |
| BIN system (`10.1371/journal.pone.0066213`) | 62 | 786 | 1,029 | 165,685 | −0.002 | −0.004 |

Two readings:

- **The barcoding lineage consolidates as the field matures.** The 2003 founding
  paper is disruptive (+0.24); its successors BOLD (2007, ≈0) and BIN (2013,
  slightly negative — nⱼ > nᵢ) are cited *alongside* the now-established barcoding
  literature (note the very large nₖ). A field settling around its origin.
- **High CD for RAxML/MAFFT is partly a low-reference artifact, not a verdict.**
  The CD index mechanically pushes papers with few references toward +1 (fewer
  references → fewer chances for a citer to co-cite one → inflated nᵢ). RAxML has
  only 15 references. Sixt & Pasin and Park et al. guard against this by
  restricting to papers with ≥10 references; even so, read software-paper scores
  with caution and compare like with like (reference count, field, era).

## Caveats

- **Network = OpenCitations.** CD is defined relative to a citation graph; a
  different/denser graph (Dimensions, WoS) gives a different number. Coverage of
  the 34 references and of early citers is whatever OpenCitations has.
- **Window dates** come from `works_by_omid.pub_date`; citers with missing/
  unparseable years fall out of the CD₅ window (not the all-time figure).
- **`works_by_omid` is not unique on OMID** — the year lookup is pre-aggregated to
  one row per OMID, else the join multiplies citers and inflates nᵢ/nⱼ/nₖ. (Same
  `doi_omid`/works non-uniqueness gotcha as elsewhere in the lake.)
- Same-publication-year (T) citations are excluded from CD₅ by the T+1..T+t
  convention, included in all-time.

## Run / reuse

```sh
duckdb lake.duckdb -c ".read views.sql" \
                   -c ".read sandbox/disruption-index/cd_index.sql"
```

Edit `focal_doi` (and `t_window`) at the top of `cd_index.sql` for another paper;
T is derived automatically from the focal paper's publication year.
