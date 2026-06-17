# GBIF - BOLD mapping

This mapping is from https://github.com/gbif/bold-dwca-pipeline

## Field mapping

How BOLD parquet columns map to Darwin Core terms, and the transformation applied. Two
transformations apply to **every** field unless noted:

- **null → empty:** `null`, `"None"` and `"null"` are emitted as an empty string.
- **clean:** literal tab / CR / LF characters are collapsed to a single space (so unquoted-TSV
  columns can't shift or rows split).

### Occurrence core → `occurrence.txt` (`dwc:Occurrence`)

| # | Darwin Core term | BOLD parquet column | Transformation |
|---|------------------|---------------------|----------------|
| 0 | *(id)* | `processid` | — |
| 1 | `occurrenceID` | `processid` | — |
| 2 | `catalogNumber` | `museumid` | clean |
| 3 | `fieldNumber` | `fieldid` | clean |
| 4 | `identificationRemarks` | `identification_method` | clean |
| 5 | `occurrenceRemarks` | `notes` | clean |
| 6 | `verbatimIdentification` | `identification` | clean |
| 7 | `identifiedBy` | `identified_by` | clean |
| 8 | `associatedOccurrences` | `associated_specimens` | clean |
| 9 | `associatedTaxa` | `associated_taxa` | clean |
| 10 | `eventDate` | `collection_date_start` | clean |
| 11 | `eventTime` | `collection_time` | clean |
| 12 | `habitat` | `habitat` | clean |
| 13 | `recordedBy` | `collectors` | clean |
| 14 | `country` | `country/ocean` | clean |
| 15 | `stateProvince` | `province/state` | clean |
| 16 | `locality` | `site` | clean |
| 17 | `coordinatePrecision` | `coord_accuracy` | clean |
| 18 | `georeferenceSources` | `coord_source` | clean |
| 19 | `maximumDepthInMeters` | `depth` | clean |
| 20 | `minimumDepthInMeters` | `depth` | clean *(same value as max)* |
| 21 | `maximumElevationInMeters` | `elev` | clean |
| 22 | `minimumElevationInMeters` | `elev` | clean *(same value as max)* |
| 23 | `eventRemarks` | `collection_notes` | clean |
| 24 | `lifestage` | `life_stage` | clean |
| 25 | `sex` | `sex` | clean |
| 26 | `associatedSequences` | `insdc_acs` | each accession prefixed with `https://www.ncbi.nlm.nih.gov/nuccore/`, multiple joined with `\|` |
| 27 | `disposition` | `voucher_type` | clean |
| 28 | `institutionCode` | `inst` | clean |
| 29 | `kingdom` | `kingdom` | clean |
| 30 | `phylum` | `phylum` | clean |
| 31 | `class` | `class` | clean |
| 32 | `order` | `order` | clean |
| 33 | `family` | `family` | clean |
| 34 | `genus` | `genus` | clean |
| 35 | `decimalLatitude` | `coord` | strip brackets, split on `,`, take part **0** |
| 36 | `decimalLongitude` | `coord` | strip brackets, split on `,`, take part **1** |
| 37 | `scientificName` | `bin_uri` → `identification` | `bin_uri` if present, else `identification` (clean) |
| 38 | `basisOfRecord` | *(constant)* | literal `MATERIAL_SAMPLE` |
| 39 | `taxonID` | `bin_uri` | — (raw BIN, e.g. `BOLD:ADC8616`) |
| 40 | `taxonConceptID` | `bin_uri` | prefixed with `https://portal.boldsystems.org/bin/` (empty if no BIN) |
| 41 | `references` (`dcterms`) | `processid` | prefixed with `https://portal.boldsystems.org/record/` |

`associatedSequences` is the only field aggregated across duplicate `processid`s (a `\|`-joined
list of all distinct accessions); every other column takes one representative value per `processid`.

### DNA extension → `dna.txt` (`gbif:DNADerivedData`)

One row per sequence-bearing record (rows with empty `nuc` are dropped); **not** deduplicated.

| # | Darwin Core term | BOLD parquet column | Transformation |
|---|------------------|---------------------|----------------|
| 0 | *(coreid)* | `processid` | — |
| 1 | `MIXS:0000044` (target_gene) | `marker_code` | clean |
| 2 | `dna_sequence` | `nuc` | newlines removed entirely (sequence kept contiguous) |
| 3 | `pcr_primer_name_forward` | `primers_forward` | clean — *currently empty (column is NULL in the parquet)* |
| 4 | `pcr_primer_name_reverse` | `primers_reverse` | clean — *currently empty (column is NULL in the parquet)* |