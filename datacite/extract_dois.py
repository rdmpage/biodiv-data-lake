#!/usr/bin/env python3
"""Extract the DOI list from the DataCite Public Data File tar — the per-month
CSVs only (doi,state,client_id,updated), never touching the huge JSONL metadata.
Stdlib only. Run from the repo root via datacite/build_parquet.sh, or:

  python3 datacite/extract_dois.py <DataCite_..._.tar> <out.tsv>

Output columns: doi, state, client_id, updated, source (the updated_YYYY-MM
folder, so the right JSONL can be found later for on-demand metadata).

The tar is plain (members individually gzipped); we open it random-access and
extractfile ONLY the *.csv.gz members, so we read their bytes + the header scan,
not the 615 GB of JSONL.
"""
import sys, tarfile, gzip, csv, io

def san(s):
    return s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ') if s else ''

def main():
    src, out = sys.argv[1], sys.argv[2]
    n = files = 0
    with open(out, 'w', newline='') as fh:
        fh.write('doi\tstate\tclient_id\tupdated\tsource\n')
        tar = tarfile.open(src, 'r')
        for m in tar:
            if not (m.isfile() and m.name.endswith('.csv.gz')):
                continue
            files += 1
            parts = m.name.split('/')
            source = parts[-2] if len(parts) >= 2 else ''     # updated_YYYY-MM
            data = gzip.decompress(tar.extractfile(m).read()).decode('utf-8', 'replace')
            rdr = csv.reader(io.StringIO(data))
            next(rdr, None)                                   # header: doi,state,client_id,updated
            for row in rdr:
                if len(row) < 4:
                    continue
                fh.write('\t'.join([san(row[0]).lower(), san(row[1]), san(row[2]),
                                    san(row[3]), source]) + '\n')
                n += 1
            if files % 20 == 0:
                print(f'  ...{files} csv files, {n:,} dois', file=sys.stderr, flush=True)
    print(f'extracted {n} dois from {files} csv files')

if __name__ == '__main__':
    main()
