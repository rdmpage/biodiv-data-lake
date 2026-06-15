-- Funder countries for papers citing BOLD datasets (sandbox/bold-citations/).
-- Path: Crossref funder -> OFR funder -> GeoNames country. iso_numeric matches the
-- `id` field of the world-110m topojson used by the Vega-Lite choropleth template.
WITH pubs AS (
  SELECT DISTINCT lower(work_doi) AS doi
  FROM read_csv('sandbox/bold-citations/datadoi_cites_workdoi.tsv', delim='\t', header=true)
)
SELECT TRY_CAST(g.iso_numeric AS INT) AS iso_numeric, g.name, count(DISTINCT cf.doi) AS papers
FROM crossref_funder cf JOIN pubs USING (doi)
JOIN ofr_funder o       ON o.fundref_id = cf.fundref_id
JOIN geonames_country g ON g.geonameid  = o.country_geonameid
WHERE g.iso_numeric IS NOT NULL
GROUP BY 1, 2 ORDER BY papers DESC;
