# sandbox

One-off explorations and test cases — "what can the lake do?" work that isn't
part of the lake's core infrastructure.

Things here are allowed to be throwaway. Scripts, notes, and small example
inputs are version-controlled; generated artifacts (Parquet, SQLite, etc.) are
gitignored. If an exploration produces something genuinely reusable, promote it
out of `sandbox/` into the relevant dataset folder or the catalog.

- `bold-citations/` — funding/authorship/preprints of papers citing BOLD datasets,
  via the Crossref layer (⋈ OFR/ROR/ORCID). Includes the source dataset↔publication
  pairing TSV so it's reproducible.
- `disruption-index/` — CD (disruption) index for a single focal paper computed
  over OpenCitations, after Sixt & Pasin (2024). Worked example: the DNA
  barcoding paper (Hebert et al. 2003), all-time CD ≈ +0.24.
- `orcid-explore/` — sample parse of the ORCID summaries dump (prototype for the
  `orcid/` dataset); the ~89% work-DOI → OpenCitations finding.
- `bhl-oc-citations/` — citation impact of BHL parts via an in-lake
  `bhl ⋈ opencitations` join (the current approach).
- `bhl-citations/` — offline SQLite precursor to the above, from before BHL was
  in the lake (hit OpenCitations per-DOI). Superseded by `bhl-oc-citations/`.
