#!/bin/sh
#
# Convert GeoNames countryInfo.txt to Parquet — the lake's country dimension /
# crosswalk (geonameid <-> iso2 <-> iso3). Source (CC BY 4.0):
#   https://download.geonames.org/export/dump/countryInfo.txt
# Drop countryInfo.txt in geonames/, then run from the repo root:
#
#   ./geonames/build_parquet.sh
#
# The file has ~50 comment lines (incl. the column header) starting with '#'.
# We do NOT use comment='#' — the Postal-Code-Format column legitimately contains
# '#' (e.g. US "#####-####"), and a comment char would truncate those rows; so we
# parse every line and drop the comment lines (iso2 LIKE '#%'). View
# geonames_country is in ../views.sql. Generated *.parquet is gitignored;
# countryInfo.txt (small source) is kept.
set -eu

DUCKDB="${DUCKDB:-duckdb}"
[ -f geonames/countryInfo.txt ] || { echo "!! geonames/countryInfo.txt not found" >&2; exit 1; }

"$DUCKDB" -c "
COPY (
  SELECT * FROM read_csv('geonames/countryInfo.txt', delim='\t', header=false,
    quote='', escape='', all_varchar=true, null_padding=true, ignore_errors=true,
    columns={'iso2':'VARCHAR','iso3':'VARCHAR','iso_numeric':'VARCHAR','fips':'VARCHAR','country':'VARCHAR','capital':'VARCHAR','area_sqkm':'VARCHAR','population':'VARCHAR','continent':'VARCHAR','tld':'VARCHAR','currency_code':'VARCHAR','currency_name':'VARCHAR','phone':'VARCHAR','postal_format':'VARCHAR','postal_regex':'VARCHAR','languages':'VARCHAR','geonameid':'VARCHAR','neighbours':'VARCHAR','fips_equiv':'VARCHAR'})
  WHERE iso2 IS NOT NULL AND iso2 NOT LIKE '#%' AND length(iso2) = 2
) TO 'geonames/geonames_country.parquet' (FORMAT parquet, COMPRESSION zstd);"
echo "done ($("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_parquet('geonames/geonames_country.parquet')") countries)"
