#!/usr/bin/env python3
"""Parse the Open Funder Registry RDF/XML (registry.rdf, FundRef SKOS) into one
TSV of funders. Stdlib only (xml.etree.iterparse, streamed). Run from repo root
via ofr/build_parquet.sh, or:

  python3 ofr/parse_registry.py <registry.rdf> <out.tsv>

Columns: fundref_id, funder_doi, name, aliases, country, region, body_type,
body_subtype, tax_id, status, broader_id, created, modified.

Both ID forms are kept: fundref_id is the bare FundRef number (e.g. 501100001780,
joins ror.fundref_id); funder_doi is the full 10.13039/<id> form (the funder
identifier Crossref uses). aliases is ';'-joined alt labels. broader_id is the
parent funder (SKOS hierarchy).
"""
import sys, csv
import xml.etree.ElementTree as ET

RDF = '{http://www.w3.org/1999/02/22-rdf-syntax-ns#}'

def local(tag):
    return tag.rsplit('}', 1)[-1]

def clean(s):
    return ' '.join(s.split()) if s else ''

def find(el, *path):
    cur = [el]
    for name in path:
        nxt = []
        for e in cur:
            nxt += [c for c in e if local(c.tag) == name]
        cur = nxt
    return cur

def text1(el, *path):
    hits = find(el, *path)
    return clean(hits[0].text) if hits and hits[0].text else ''

def main():
    src, out = sys.argv[1], sys.argv[2]
    w = csv.writer(open(out, 'w', newline=''), delimiter='\t')
    # fundref_id = bare number (joins ror.fundref_id); funder_doi = full
    # 10.13039/<id> (the form Crossref uses as the funder identifier). Keep both.
    w.writerow(['fundref_id','funder_doi','name','aliases','country','region',
                'body_type','body_subtype','tax_id','status','broader_id','created','modified'])
    n = 0
    for ev, el in ET.iterparse(src, events=('end',)):
        if local(el.tag) != 'Concept':
            continue
        about = el.get(RDF + 'about', '')
        fdoi = about.replace('http://dx.doi.org/', '')           # 10.13039/<id>
        fid  = fdoi.replace('10.13039/', '')                     # bare <id>
        aliases = ';'.join(clean(x.text) for x in find(el, 'altLabel', 'Label', 'literalForm') if x.text)
        status = ''
        s = find(el, 'status')
        if s:
            status = (s[0].get(RDF + 'resource', '') or s[0].text or '').rsplit('/', 1)[-1]
        broader = ''
        b = find(el, 'broader')
        if b:
            broader = b[0].get(RDF + 'resource', '').replace('http://dx.doi.org/10.13039/', '')
        w.writerow([fid, fdoi,
                    text1(el, 'prefLabel', 'Label', 'literalForm'),
                    aliases,
                    text1(el, 'address', 'postalAddress', 'addressCountry'),
                    text1(el, 'region'),
                    text1(el, 'fundingBodyType'),
                    text1(el, 'fundingBodySubType'),
                    text1(el, 'taxId'),
                    status, broader,
                    text1(el, 'created'), text1(el, 'modified')])
        n += 1
        el.clear()
    print(f'parsed {n} funders')

if __name__ == '__main__':
    main()
