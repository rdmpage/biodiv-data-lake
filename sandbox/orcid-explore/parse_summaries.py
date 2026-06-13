#!/usr/bin/env python3
"""Stream-parse a (possibly truncated) ORCID summaries .tar.gz sample into two
TSVs, using only the stdlib. Exploration only — see sandbox/orcid-explore/README.

  python3 parse_summaries.py <sample.tar.gz> <out_prefix> [max_records]

Emits:
  <out_prefix>_person.tsv : orcid, given, family, credit, country, n_emp, n_work, n_doi
  <out_prefix>_work.tsv   : orcid, doi, title, type   (one row per work DOI)

The sample is a prefix of a 46 GB tar, so the final member is usually truncated;
we stop cleanly on the first read/parse error after processing whole records.
"""
import sys, tarfile, csv
import xml.etree.ElementTree as ET

def local(tag):                      # strip {namespace}
    return tag.rsplit('}', 1)[-1]

def clean(s):                        # collapse tabs/newlines/runs -> single spaces
    return ' '.join(s.split()) if s else ''

def find(el, *path):                 # first descendant matching a local-name path
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

def parse_record(xml_bytes):
    root = ET.fromstring(xml_bytes)
    orcid = text1(root, 'orcid-identifier', 'path')
    name_el = find(root, 'person', 'name')
    given = family = credit = ''
    if name_el:
        given  = text1(name_el[0], 'given-names')
        family = text1(name_el[0], 'family-name')
        credit = text1(name_el[0], 'credit-name')
    country = ''
    addr = find(root, 'person', 'addresses', 'address', 'country')
    if addr and addr[0].text:
        country = clean(addr[0].text)
    n_emp = len(find(root, 'activities-summary', 'employments', 'affiliation-group',
                     'employment-summary'))
    works, dois = [], []
    for ws in find(root, 'activities-summary', 'works', 'group', 'work-summary'):
        title = text1(ws, 'title', 'title')
        wtype = text1(ws, 'type')
        wdoi = ''
        for eid in find(ws, 'external-ids', 'external-id'):
            t = text1(eid, 'external-id-type').lower()
            v = text1(eid, 'external-id-value').strip()
            if t == 'doi' and v:
                wdoi = v.lower(); break
        works.append((title, wtype, wdoi))
        if wdoi:
            dois.append((wdoi, title, wtype))
    return (orcid, given, family, credit, country, n_emp, len(works), len(dois)), dois

def main():
    src, prefix = sys.argv[1], sys.argv[2]
    cap = int(sys.argv[3]) if len(sys.argv) > 3 else 50000
    n = 0
    with open(f'{prefix}_person.tsv', 'w', newline='') as pf, \
         open(f'{prefix}_work.tsv', 'w', newline='') as wf:
        pw = csv.writer(pf, delimiter='\t'); ww = csv.writer(wf, delimiter='\t')
        pw.writerow(['orcid','given','family','credit','country','n_emp','n_work','n_doi'])
        ww.writerow(['orcid','doi','title','type'])
        tar = tarfile.open(src, mode='r|gz')
        try:
            for m in tar:
                if not (m.isfile() and m.name.endswith('.xml')):
                    continue
                try:
                    data = tar.extractfile(m).read()
                    person, dois = parse_record(data)
                except Exception:
                    break            # truncated tail or bad XML -> stop cleanly
                pw.writerow(person)
                for d in dois:
                    ww.writerow([person[0], d[0], d[1], d[2]])
                n += 1
                if n >= cap:
                    break
        except Exception:
            pass
    print(f'parsed {n} records')

if __name__ == '__main__':
    main()
