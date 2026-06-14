<?php
// Fetch Crossref work metadata for a list of DOIs and cache each record to disk,
// prefix-foldered. We hit the REST API directly (not content negotiation), so the
// work is wrapped in a "message" envelope — we unwrap and cache just the work.
//
//   CROSSREF_MAILTO=you@example.org php crossref/fetch.php <doi-list.txt> [more.txt ...]
//   php crossref/fetch.php --force <doi-list.txt>      # re-fetch even if cached
//
// Idempotent: re-running only fetches DOIs not already cached, so adding DOIs
// over time just means appending to a list (or adding another list file) and
// re-running. Build the Parquet afterwards with crossref/build_parquet.sh.
//
// Cache: crossref/cache/<prefix>/<doi, / and : -> ->.json   (one work per file)
// Not-found / errors are logged to crossref/failed.txt (tab-separated).

$mailto = getenv('CROSSREF_MAILTO');
if (!$mailto) {
    fwrite(STDERR, "warning: set CROSSREF_MAILTO=you@example.org for the polite pool\n");
    $mailto = 'anonymous@example.org';
}

$force = false;
$files = array();
foreach (array_slice($argv, 1) as $a) {
    if ($a === '--force') { $force = true; } else { $files[] = $a; }
}
if (count($files) == 0) {
    fwrite(STDERR, "usage: php fetch.php [--force] <doi-list.txt> ...\n");
    exit(1);
}

$cache_root = dirname(__FILE__) . '/cache';
$failed_log = dirname(__FILE__) . '/failed.txt';

// Gather DOIs from the list file(s): dedup, lowercase, skip blanks/# comments,
// strip any doi.org/ URL prefix so plain DOIs and URLs both work.
$dois = array();
foreach ($files as $f) {
    foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $doi = strtolower(trim($line));
        if ($doi === '' || $doi[0] === '#') { continue; }
        $doi = preg_replace('#^https?://(dx\.)?doi\.org/#', '', $doi);
        $dois[$doi] = true;
    }
}
$dois = array_keys($dois);

$fetched = $skipped = $failed = 0;
foreach ($dois as $doi) {
    $path = cache_path($cache_root, $doi);
    if (!$force && file_exists($path)) { $skipped++; continue; }

    // Keep the literal '/' between prefix and suffix; encode the rest.
    $encoded = str_replace('%2F', '/', rawurlencode($doi));
    $url = 'https://api.crossref.org/works/' . $encoded . '?mailto=' . rawurlencode($mailto);

    list($body, $code) = http_get($url, $mailto);

    if ($code == 200 && $body) {
        $obj = json_decode($body);
        if ($obj && isset($obj->message)) {            // unwrap the envelope
            @mkdir(dirname($path), 0777, true);
            file_put_contents($path, json_encode($obj->message));
            $fetched++;
        } else {
            log_fail($failed_log, $doi, 'no message'); $failed++;
        }
    } elseif ($code == 404) {
        log_fail($failed_log, $doi, 'not found');       // e.g. a DataCite-only DOI
        $failed++;
    } else {
        log_fail($failed_log, $doi, 'http ' . $code);   // transient — safe to retry later
        $failed++;
    }

    usleep(150000);   // ~6-7 req/s; the polite pool tolerates this
}
fwrite(STDERR, "fetched=$fetched  skipped(cached)=$skipped  failed=$failed\n");

//----------------------------------------------------------------------------------------
function cache_path($root, $doi)
{
    $prefix = explode('/', $doi)[0];                    // e.g. 10.3897
    $name = preg_replace('#[/:]#', '-', $doi) . '.json';
    return $root . '/' . $prefix . '/' . $name;
}

function log_fail($log, $doi, $why)
{
    file_put_contents($log, $doi . "\t" . $why . "\t" . date('c') . "\n", FILE_APPEND);
}

function http_get($url, $mailto)
{
    $ch = curl_init();
    curl_setopt_array($ch, array(
        CURLOPT_URL            => $url,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_TIMEOUT        => 60,
        CURLOPT_USERAGENT      => 'biodiv-data-lake/1.0 (mailto:' . $mailto . ')',
        CURLOPT_HTTPHEADER     => array('Accept: application/json'),
    ));
    $body = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return array($body, $code);
}
?>
