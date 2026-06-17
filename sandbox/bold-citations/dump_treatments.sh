#!/bin/sh
#
# Dump the Plazi taxonomic treatments contained in the BOLD-citing papers as one
# UTF-8 text file per treatment. For a Plazi treatment the Zenodo 'Abstract'
# description IS the full treatment text. Chain (all via views.sql):
#   work_doi (a paper citing a BOLD dataset, datadoi_cites_workdoi.tsv)
#     -> zenodo_record carrying that same publisher DOI (doi_is_zenodo = false)
#     -> treatments that are IsPartOf it (resource_subtype 'Taxonomic treatment')
#     -> zenodo_description Abstract (the text).
# ~2,549 treatments across ~204 of the 487 BOLD-citing papers that are in Zenodo.
#
# Run from the repo root (needs duckdb + python3):
#   ./sandbox/bold-citations/dump_treatments.sh        # all treatments
#   ./sandbox/bold-citations/dump_treatments.sh 20     # cap to 20 (quick sample)
#
# Writes sandbox/bold-citations/treatments/<zenodo_id>_<slug>.txt. That directory is
# gitignored: the treatment text is Plazi/Zenodo content and is regenerable from the
# lake, so it is never committed.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
OUT="sandbox/bold-citations/treatments"
LIMIT_CLAUSE=""
[ "${1:-}" ] && LIMIT_CLAUSE="LIMIT $1"
mkdir -p "$OUT"

"$DUCKDB" lake.duckdb -c ".read views.sql" -c "
COPY (
  WITH bold_citers AS (
    SELECT DISTINCT lower(work_doi) AS doi
    FROM read_csv('sandbox/bold-citations/datadoi_cites_workdoi.tsv', delim='\t', header=true)
  ),
  articles AS (
    SELECT DISTINCT z.doi FROM zenodo_record z JOIN bold_citers b ON b.doi = z.doi
    WHERE z.doi_is_zenodo = false
  ),
  treatments AS (
    SELECT t.zenodo_id, t.title, rel.doi AS article_doi
    FROM zenodo_record t
    JOIN zenodo_related rel ON rel.zenodo_id = t.zenodo_id AND rel.relation = 'IsPartOf'
    JOIN articles a ON a.doi = rel.doi
    WHERE t.resource_subtype = 'Taxonomic treatment'
  )
  SELECT t.zenodo_id, t.article_doi, t.title, d.text
  FROM treatments t
  JOIN zenodo_description d ON d.zenodo_id = t.zenodo_id AND d.description_type = 'Abstract'
  ORDER BY t.article_doi, t.zenodo_id
  $LIMIT_CLAUSE
) TO '$OUT/_treatments.jsonl' (FORMAT json);"

python3 - "$OUT" <<'PY'
import json, os, re, sys
outdir = sys.argv[1]
src = os.path.join(outdir, "_treatments.jsonl")
rows = [json.loads(l) for l in open(src) if l.strip()]
for r in rows:
    slug = re.sub(r'[^A-Za-z0-9]+', '_', f"{r['zenodo_id']}_{(r['title'] or '')[:40]}").strip('_')
    with open(os.path.join(outdir, slug + ".txt"), "w") as f:
        f.write(f"# zenodo_id: {r['zenodo_id']}\n# article_doi: {r['article_doi']}\n# title: {r['title']}\n\n")
        f.write(r['text'] or "")
os.remove(src)
print(f"wrote {len(rows)} treatment files to {outdir}/")
PY
