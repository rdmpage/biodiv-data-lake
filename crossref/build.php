<?php
// Flatten the cached Crossref works (crossref/cache/**/*.json) into four TSVs.
// crossref/build_parquet.sh then converts them to Parquet for the lake.
//   php crossref/build.php
//
// Text fields are whitespace-collapsed so the tab-delimited output is safe to
// load with quote='' (the lake's convention). Re-run any time — it rebuilds the
// TSVs from the whole cache, so newly fetched DOIs are picked up automatically.

$cache = dirname(__FILE__) . '/cache';
$out   = dirname(__FILE__);

function clean($s) { return $s === null ? '' : trim(preg_replace('/\s+/u', ' ', (string)$s)); }
function arr($o, $k) { return (isset($o->$k) && is_array($o->$k)) ? $o->$k : array(); }
function first($o, $k) { $a = arr($o, $k); return count($a) ? $a[0] : ''; }
function row($h, $cols) { fwrite($h, implode("\t", array_map('clean', $cols)) . "\n"); }

$w = fopen("$out/crossref_work.tsv", 'w');
$a = fopen("$out/crossref_author.tsv", 'w');
$f = fopen("$out/crossref_funder.tsv", 'w');
$r = fopen("$out/crossref_reference.tsv", 'w');
row($w, ['doi','type','title','container_title','publisher','issn','year',
         'is_referenced_by_count','n_authors','n_references','n_funders','license','url','abstract']);
row($a, ['doi','seq','given','family','orcid','affiliation']);
row($f, ['doi','funder_doi','fundref_id','name','awards']);
row($r, ['doi','key','cited_doi','unstructured']);

$it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($cache, FilesystemIterator::SKIP_DOTS));
$n = 0;
foreach ($it as $file) {
    if (strtolower($file->getExtension()) !== 'json') { continue; }
    $o = json_decode(file_get_contents($file->getPathname()));
    if (!$o || !isset($o->DOI)) { continue; }
    $doi = strtolower($o->DOI);

    $year = isset($o->issued->{'date-parts'}[0][0]) ? $o->issued->{'date-parts'}[0][0] : '';
    $issn = (isset($o->ISSN) && is_array($o->ISSN)) ? implode(';', $o->ISSN) : '';
    $license = isset($o->license[0]->URL) ? $o->license[0]->URL : '';
    $authors = arr($o, 'author'); $funders = arr($o, 'funder'); $refs = arr($o, 'reference');

    row($w, [$doi, $o->type ?? '', first($o, 'title'), first($o, 'container-title'),
             $o->publisher ?? '', $issn, $year, $o->{'is-referenced-by-count'} ?? '',
             count($authors), count($refs), count($funders), $license, $o->URL ?? '', $o->abstract ?? '']);

    foreach ($authors as $i => $au) {
        $orcid = '';
        if (isset($au->ORCID) && preg_match('#(\d{4}-\d{4}-\d{4}-\d{3}[\dxX])#', $au->ORCID, $m)) {
            $orcid = strtoupper($m[1]);
        }
        $aff = array();
        foreach (arr($au, 'affiliation') as $af) { if (isset($af->name)) { $aff[] = clean($af->name); } }
        row($a, [$doi, $i, $au->given ?? '', $au->family ?? '', $orcid, implode(';', $aff)]);
    }
    foreach ($funders as $fu) {
        $fdoi = isset($fu->DOI) ? strtolower($fu->DOI) : '';
        row($f, [$doi, $fdoi, str_replace('10.13039/', '', $fdoi), $fu->name ?? '',
                 implode(';', arr($fu, 'award'))]);
    }
    foreach ($refs as $ref) {
        row($r, [$doi, $ref->key ?? '', isset($ref->DOI) ? strtolower($ref->DOI) : '',
                 $ref->unstructured ?? '']);
    }
    $n++;
}
fwrite(STDERR, "flattened $n works\n");
?>
