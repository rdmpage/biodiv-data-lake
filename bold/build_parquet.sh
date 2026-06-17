#!/bin/sh
#
# Convert the BOLD Public BCDM snapshot (TSV inside the release tarball) to Parquet,
# applying the BCDM -> Darwin Core mapping in bold/rdmp_mapping.md.
# Source: BOLD Public Data Package (BCDM), CC-BY-SA-4.0,
#   https://www.boldsystems.org/  (BOLD_Public.<date>.tar.gz -> .tsv + datapackage.json)
# Drop the tarball in bold/, then run from the repo root:
#
#   ./bold/build_parquet.sh
#
# The TSV is streamed straight out of the tarball into a staging table (one
# decompression, no multi-GB temp file), then three Parquets are written:
#
#   bold_occurrence.parquet  one row per specimen   (key processid = occurrenceID)
#   bold_marker.parquet      one row per raw record (specimen x marker); minted
#                            deterministic surrogate bold_record_id; FK occurrenceID
#   bold_recordset.parquet   exploded bridge: occurrenceID -> recordset_code. DOIs are
#                            NOT synthesized here — most recordsets have none (only
#                            ~2,600 of ~13,900 DS-* recordsets are registered in
#                            DataCite). Resolve to real DOIs downstream by joining
#                            recordset_code to datacite_doi (../views.sql) -> the
#                            citation layer (sandbox/bold-citations/).
#
# Key decisions (see bold/rdmp_mapping.md for the full crosswalk + rationale):
#   * Missing values: BOLD writes both the literal 'None' AND '' -> coerced to NULL.
#   * processid is NOT row-unique (multiple markers/specimen) -> two grains; the
#     marker surrogate key is ROW_NUMBER() over a stable sort so rebuilds reproduce
#     identical ids (safe to re-run with more columns later).
#   * scientificName reserved for FORMAL names (regex gate); informal names fall to
#     verbatimIdentification = coalesce(identification, species).
#   * Many BCDM columns are intentionally omitted for now (nuc/sequences, dates,
#     sex, habitat, voucher_type, ...). The raw tarball is the retained source of
#     truth, so adding them later is an additive re-run. Adapter views: ../views.sql.
# Generated bold/*.parquet are gitignored; the tarball is too (*.tar.gz).
set -eu

DUCKDB="${DUCKDB:-duckdb}"
TARBALL=$(ls bold/BOLD_Public.*.tar.gz 2>/dev/null | head -1 || true)
[ -n "$TARBALL" ] || { echo "!! no bold/BOLD_Public.*.tar.gz found" >&2; exit 1; }
TSV=$(basename "$TARBALL" .tar.gz).tsv
TMPDB="bold/.bold_build.duckdb"
mkdir -p .tmp
rm -f "$TMPDB" "$TMPDB.wal"

echo "== streaming $TSV out of $TARBALL into staging + writing Parquet"
tar -xzOf "$TARBALL" "$TSV" | "$DUCKDB" "$TMPDB" -c "
PRAGMA temp_directory='.tmp';

-- BOLD encodes missing values two ways; collapse both to NULL everywhere.
CREATE MACRO clean(x) AS nullif(nullif(trim(x), ''), 'None');

-- Read the streamed TSV; keep + clean only the mapped columns. quote='' so stray
-- quotes are literal; all_varchar so nothing is type-sniffed off a pipe.
CREATE OR REPLACE TABLE staging AS
SELECT
  clean(processid)                      AS processid,
  TRY_CAST(clean(specimenid) AS BIGINT) AS specimenid,
  clean(museumid)                       AS museumid,
  clean(fieldid)                        AS fieldid,
  clean(inst)                           AS inst,
  clean(collection_code)                AS collection_code,
  clean(bin_uri)                        AS bin_uri,
  clean(kingdom)  AS kingdom, clean(phylum) AS phylum, clean(\"class\") AS \"class\",
  clean(\"order\") AS \"order\", clean(family) AS family, clean(subfamily) AS subfamily,
  clean(tribe)    AS tribe,   clean(genus)  AS genus,
  clean(species)                        AS species,
  clean(subspecies)                     AS subspecies,
  clean(species_reference)              AS species_reference,
  clean(identification)                 AS identification,
  clean(identification_method)          AS identification_method,
  clean(identification_rank)            AS identification_rank,
  clean(identified_by)                  AS identified_by,
  clean(taxonomy_notes)                 AS taxonomy_notes,
  clean(coord)                          AS coord,
  clean(coord_source)                   AS coord_source,
  clean(\"country/ocean\")              AS country_ocean,
  clean(country_iso)                    AS country_iso,
  clean(\"province/state\")             AS province_state,
  clean(region)                         AS region,
  clean(site)                           AS site,
  clean(insdc_acs)                      AS insdc_acs,
  clean(marker_code)                    AS marker_code,
  clean(bold_recordset_code_arr)        AS recordset_arr
FROM read_csv('/dev/stdin', delim='\t', header=true, quote='', escape='',
              all_varchar=true, null_padding=true);

-- ---- occurrence: one row per specimen (processid) ----------------------------
COPY (
  SELECT
    processid                                                          AS \"occurrenceID\",
    specimenid,
    museumid                                                           AS \"catalogNumber\",
    fieldid                                                            AS \"fieldNumber\",
    inst                                                               AS \"institutionCode\",
    collection_code                                                    AS \"collectionCode\",
    TRY_CAST(trim(split_part(regexp_replace(coord,'[\[\]]','','g'),',',1)) AS DOUBLE) AS \"decimalLatitude\",
    TRY_CAST(trim(split_part(regexp_replace(coord,'[\[\]]','','g'),',',2)) AS DOUBLE) AS \"decimalLongitude\",
    coord_source                                                       AS \"georeferenceSources\",
    country_ocean                                                      AS \"higherGeography\",
    province_state                                                     AS \"stateProvince\",
    region                                                             AS \"county\",
    country_iso                                                        AS \"countryCode\",
    site                                                               AS \"locality\",
    bin_uri                                                            AS \"taxonID\",
    coalesce(identification, species)                                  AS \"verbatimIdentification\",
    identified_by                                                      AS \"identifiedBy\",
    identification_method                                              AS \"identificationType\",
    identification_rank                                                AS \"taxonRank\",
    taxonomy_notes                                                     AS \"identificationRemarks\",
    kingdom, phylum, \"class\", \"order\", family, subfamily, tribe, genus,
    -- names: epithets + scientificName only when the value is a FORMAL binomial/trinomial
    CASE WHEN regexp_matches(species,    '^\p{Lu}[\p{Ll}-]+ [\p{Ll}-]{2,}\$')
         THEN split_part(species, ' ', 2) END                         AS \"specificEpithet\",
    CASE WHEN regexp_matches(subspecies, '^\p{Lu}[\p{Ll}-]+ [\p{Ll}-]{2,} [\p{Ll}-]{2,}\$')
         THEN split_part(subspecies, ' ', 3) END                      AS \"infraspecificEpithet\",
    CASE
      WHEN regexp_matches(subspecies, '^\p{Lu}[\p{Ll}-]+ [\p{Ll}-]{2,} [\p{Ll}-]{2,}\$') THEN subspecies
      WHEN regexp_matches(species,    '^\p{Lu}[\p{Ll}-]+ [\p{Ll}-]{2,}\$')               THEN species
    END                                                                AS \"scientificName\",
    species_reference                                                  AS \"scientificNameAuthorship\"  -- TODO: UTF-8/Latin-1 mojibake not yet fixed
  FROM staging
  WHERE processid IS NOT NULL
  QUALIFY row_number() OVER (PARTITION BY processid ORDER BY specimenid, marker_code, insdc_acs) = 1
) TO 'bold/bold_occurrence.parquet' (FORMAT parquet, COMPRESSION zstd);

-- ---- marker: one row per raw record; deterministic minted surrogate key ------
COPY (
  SELECT
    row_number() OVER (ORDER BY processid, marker_code NULLS LAST, insdc_acs NULLS LAST) AS bold_record_id,
    processid     AS \"occurrenceID\",
    marker_code   AS \"target_gene\",
    insdc_acs     AS \"associatedSequences\"
  FROM staging
  WHERE processid IS NOT NULL
) TO 'bold/bold_marker.parquet' (FORMAT parquet, COMPRESSION zstd);

-- ---- recordset bridge: explode the recordset/project codes (occurrenceID -> code).
-- Do NOT synthesize dataset DOIs here: most recordsets have none. Real DOIs are a
-- validated join to datacite_doi downstream (see ../views.sql).
COPY (
  SELECT DISTINCT
    processid AS \"occurrenceID\",
    code      AS recordset_code
  FROM (
    SELECT processid, trim(x) AS code
    FROM staging, UNNEST(string_split(regexp_replace(recordset_arr,'[\[\]'' ]','','g'), ',')) AS t(x)
    WHERE recordset_arr IS NOT NULL AND processid IS NOT NULL
  )
  WHERE code <> ''
) TO 'bold/bold_recordset.parquet' (FORMAT parquet, COMPRESSION zstd);
"

rm -f "$TMPDB" "$TMPDB.wal"
echo "== done"
for f in occurrence marker recordset; do
  printf '   bold_%s.parquet\t%s rows\n' "$f" \
    "$("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_parquet('bold/bold_$f.parquet')")"
done
