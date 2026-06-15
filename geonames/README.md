# Geonames

Small subset of [GeoNames](https://www.geonames.org) data so we can match geoname ids to countries.

## Source

https://download.geonames.org/export/dump/countryInfo.txt, data is licensed under a [Creative Commons Attribution 4.0 License](https://creativecommons.org/licenses/by/4.0/).

`countryInfo.txt` (small, kept in git) is the only file so far — country-level
only. The full `allCountries` (places, hierarchy) is deferred until sub-country
geography is needed.

## Build

```sh
./geonames/build_parquet.sh        # countryInfo.txt -> geonames_country.parquet
```

The header + comment lines start with `#`, but we can't use `comment='#'` — the
Postal-Code-Format column contains `#` (e.g. US `#####-####`), which would
truncate those rows — so the loader parses every line and drops the comment
lines. View `geonames_country` is in `../views.sql`.

## Table (view in `../views.sql`)

`geonames_country` — one row per country (252): `geonameid, iso2, iso3,
iso_numeric, name, capital, continent, population, area_sqkm, currency_code,
languages`.

## The crosswalk

The **country dimension** that ties the lake's geographic codes together:

| source | column | joins `geonames_country` on |
|---|---|---|
| OFR funders | `ofr_funder.country_geonameid` | `geonameid` (from the funder's `svf:country`) |
| OFR funders | `ofr_funder.country` (ISO3-ish, e.g. `usa`) | `lower(iso3)` |
| ROR orgs | `ror.country_code` | `iso2` |
| ORCID people | `orcid_person.country` | `iso2` |

```sql
-- funder countries for papers citing BOLD datasets, canonical via GeoNames
SELECT g.name, g.continent, count(DISTINCT cf.doi) papers
FROM crossref_funder cf
JOIN ofr_funder o       ON o.fundref_id = cf.fundref_id
JOIN geonames_country g ON g.geonameid  = o.country_geonameid
GROUP BY 1,2 ORDER BY papers DESC;
```

Coverage: 45,470 / 45,700 OFR funders resolve via `country_geonameid`; all ROR
country codes resolve via ISO2. Using OFR→GeoNames for funder country is more
complete than ROR's sparse FundRef crosswalk (fills Germany/Czech/etc. gaps).
