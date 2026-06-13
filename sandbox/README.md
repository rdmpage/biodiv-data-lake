# sandbox

One-off explorations and test cases — "what can the lake do?" work that isn't
part of the lake's core infrastructure.

Things here are allowed to be throwaway. Scripts, notes, and small example
inputs are version-controlled; generated artifacts (Parquet, SQLite, etc.) are
gitignored. If an exploration produces something genuinely reusable, promote it
out of `sandbox/` into the relevant dataset folder or the catalog.

- `bhl-oc-citations/` — citation impact of BHL parts via an in-lake
  `bhl ⋈ opencitations` join (the current approach).
- `bhl-citations/` — offline SQLite precursor to the above, from before BHL was
  in the lake (hit OpenCitations per-DOI). Superseded by `bhl-oc-citations/`.
