# BCDM → Darwin Core mapping (rdmp)

Follows the GBIF mapping closely, but reserves `scientificName` for formal taxonomic
names and keeps the BOLD recordset codes as an explicit bridge to the dataset DOIs.

## Grain & keys

The dump is **22,484,596 rows**. `processid` is **not** row-unique: 0.93% of
processids (206,438) repeat, accounting for 2.5% of rows; `specimenid` is its 1:1
integer twin and shares the same duplication. The repeats are **multiple markers per
specimen** — `(processid, marker_code)` is unique for all but 7 rows (7 true
same-specimen/same-marker duplicates, mostly GenBank-mined `CYTB`). So we split into
two tables:

| table | grain | key |
|--|--|--|
| **occurrence** | one row per specimen | `processid` (= `specimenid`); `occurrenceID = processid`. Dedup the 0.93% repeats. |
| **marker** | one row per specimen × marker | **minted surrogate integer PK** (no natural column is perfectly unique); `(processid, marker_code)` is the near-unique business key and the FK back to occurrence. |

Relationship: occurrence `1 ——< marker` on `processid`. The sections below feed the
**occurrence** table except *marker* (`insdc_acs`, `marker_code` → the **marker**
table). Sequences themselves (`nuc`) are **not** ingested for now. The
`bold_recordset_code_arr` codes are retained as a separate exploded bridge
(`occurrenceID → recordset_code`), not a Darwin Core term. **DOIs are NOT constructed
from the codes** — most recordsets have none (only ~2,600 of ~13,900 `DS-*` recordsets
are registered in DataCite); resolve to real DOIs by joining `recordset_code`'s
candidate `10.5883/ds-*` to `datacite_doi`.

## Cleaning / missing values

BOLD serializes missing values **two** ways, and the `datapackage.json` declares no
`missingValues`, so a schema-conformant reader would treat them as real data. Of the
1,708,829,296 cells (76 cols × 22.48M rows), ~43% are missing:

- `None` — the literal Python string (585,031,148 cells, 34.2%)
- *empty string* — (144,313,167 cells, 8.4%)

**Global ingest rule: coerce `{ '', 'None' } → NULL` on every column.** Until applied,
all counts are wrong (e.g. `species` looks 100% populated but is really 34%).

Do **not** blanket-null the long tail — all rare and ambiguous: `NA` (17,303),
`unknown` (9,961, a legitimate value in `sex`/`life_stage`/`reproduction`), `NaN`
(129), `-`/`--` (344), `?` (329), `null`/`NULL` (20), `N/A` (15). Handle per-field
only if one actually bites.

## Problematic terms

`voucher_type` is supposedly a controlled term, but has a lot of rubbish. We can parse
to extract type status

`identification` is often not a formal taxonomic name

## coordinates

We need to extract the coordinates from a single value, and store the source as many 
are "Coordinates from country centroid" and are hence potentially misleading

| BOLD | parquet |
|--|--|
| coord | strip brackets, split on `,`, part 0 is decimalLatitude, part 1 is decimalLongitude |
| coord_source | georeferenceSources |

## locality

| BOLD | parquet |
|--|--|
| country/ocean | higherGeography |
| province/state | stateProvince |
| region | county |
| country_iso | countryCode |
| site | locality |

## occurrence

| BOLD | parquet |
|--|--|
| processid | occurrenceID |
| museumid | catalogNumber |
| fieldid | fieldNumber |
| inst | institutionCode |
| collection_code | collectionCode |

## marker

GBIF uses `target_gene` MIXS:0000044

| BOLD | parquet |
|--|--|
| insdc_acs | associatedSequences |
| marker_code | target_gene |


## cluster

| BOLD | parquet |
|--|--|
| bin_uri | taxonID |

## identification

We reserve `scientificName` for formal taxonomic names (see *species / subspecies*).

`identification_rank` is the rank the specimen was identified to (species / genus / BIN
/ …). DwC has no dedicated "rank of the identification" term, so we map it to `taxonRank`
— strictly the rank of the *name*, but the closest fit, and it keeps joins to GBIF
simple. It also disambiguates the 66% of records not identified to species.

`verbatimIdentification` is fed by **`coalesce(identification, species)`** — the explicit
`identification` string when present, else the `species` value — so every non-formal name
(an informal `species` not promoted to `scientificName`) is still captured and queryable
here.

| BOLD | parquet |
|--|--|
| identification | verbatimIdentification |
| identified_by | identifiedBy |
| identification_method | identificationType |
| identification_rank | taxonRank |
| taxonomy_notes | identificationRemarks |

## taxonomy

| BOLD | parquet |
|--|--|
| `kingdom` | `kingdom` | 
| `phylum`  | `phylum` |
| `class`   | `class` | 
| `order`   | `order` | 
| `family`  | `family` | 
| `subfamily`  | `subfamily` | 
| `tribe`  | `tribe` | 
| `genus`   | `genus` | 

## species / subspecies (needs parsing)

BOLD `species` is the full **binomial** ("Arhodia lasiocamparia") and `subspecies` the
full **trinomial**, whereas DwC `specificEpithet` / `infraspecificEpithet` want only the
epithet. So these need parsing, not a direct column map. Measured (after the `None`/`''`
→ NULL clean):

- **34%** of rows (7,635,805) have a real `species`; 66% are unidentified to species.
  `subspecies` is sparse — 98,160 rows (0.44%).
- `species` begins with the `genus` value in **99.91%** of named rows (only 6,768 don't),
  so `specificEpithet` = `species` minus the leading `genus␣` is safe; flag the residue.
- **~14%** of named `species` (1,073,384) carry informal markers (`sp.`, `cf.`, `nr.`,
  `aff.`, a digit, `complex`, `group`) — a regex gate detects these. This is the
  *formal vs informal* test for whether a value earns `scientificName`. Caveat: it is a
  syntax gate, not validity — e.g. `Homo sapiens` (72,000 rows, contamination) passes.
- `species_reference` (→ `scientificNameAuthorship`) has **mojibake** ("GuenÃ©e, 1858" =
  "Guenée, 1858"): fix UTF-8/Latin-1 encoding on ingest.

**Mapping (decided).** Epithets and `scientificName` are populated **only for formal
names** (the regex gate above); informal values fall through to `verbatimIdentification`
(see *identification*).

| BOLD | parquet | rule |
|--|--|--|
| species | specificEpithet | formal only: `species` minus the leading `genus␣` |
| subspecies | infraspecificEpithet | formal only: final token of the trinomial |
| species / subspecies | scientificName | the formal trinomial (`subspecies`) if present & formal, else the formal binomial (`species`); else NULL |
| species_reference | scientificNameAuthorship | fix mojibake; some values may not be true authorship |

This makes `WHERE scientificName IS NULL AND verbatimIdentification IS NOT NULL` the query
for records whose name is informal / not a proper binomial.






