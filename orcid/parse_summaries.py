#!/usr/bin/env python3
"""Stream-parse the ORCID public-data-file summaries .tar.gz into two TSVs using
only the stdlib (no lxml/pyarrow). Streaming, so the 20M+ tiny XML files are
never extracted to disk. Run from the repo root via orcid/build_parquet.sh, or:

  python3 orcid/parse_summaries.py <summaries.tar.gz> <out_prefix> [max_records]

Emits (then build_parquet.sh converts to Parquet):
  <out_prefix>_person.tsv : orcid, given, family, credit, country, n_emp, n_work, n_doi
  <out_prefix>_work.tsv   : orcid, doi, title, type   (one row per work DOI)

Parse with no quoting and sanitize whitespace — ORCID name/title fields contain
literal tabs/newlines. doi is lowercased (joins doi_omid / bhl_doi / col_reference).
The prototype this grew from is sandbox/orcid-explore/.
"""
import sys, tarfile, csv
import xml.etree.ElementTree as ET

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

# affiliation summary containers under activities-summary (each holds an
# <organization> with name/address and an optional disambiguated id + source)
AFFIL_CONTAINERS = {'employments', 'educations', 'qualifications',
                    'invited-positions', 'memberships', 'services', 'distinctions'}

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
    # affiliations: organisation (with its disambiguated id + source) per
    # affiliation summary. org_source in {ROR, GRID, FUNDREF, RINGGOLD, LEI, ...};
    # for ROR the id is a ror.org URL, for GRID a grid.* id (-> ror.grid_id).
    affils = []
    for act in find(root, 'activities-summary'):
        for cont in act:
            atype = local(cont.tag)
            if atype not in AFFIL_CONTAINERS:
                continue
            for org in [e for e in cont.iter() if local(e.tag) == 'organization']:
                affils.append((atype,
                    text1(org, 'name'),
                    text1(org, 'address', 'city'),
                    text1(org, 'address', 'country'),
                    text1(org, 'disambiguated-organization', 'disambiguated-organization-identifier'),
                    text1(org, 'disambiguated-organization', 'disambiguation-source')))
    return (orcid, given, family, credit, country, n_emp, len(works), len(dois)), dois, affils

def main():
    src, prefix = sys.argv[1], sys.argv[2]
    cap = int(sys.argv[3]) if len(sys.argv) > 3 else 0     # 0 = no limit
    n = 0
    with open(f'{prefix}_person.tsv', 'w', newline='') as pf, \
         open(f'{prefix}_work.tsv', 'w', newline='') as wf, \
         open(f'{prefix}_affiliation.tsv', 'w', newline='') as af:
        pw = csv.writer(pf, delimiter='\t'); ww = csv.writer(wf, delimiter='\t')
        aw = csv.writer(af, delimiter='\t')
        pw.writerow(['orcid','given','family','credit','country','n_emp','n_work','n_doi'])
        ww.writerow(['orcid','doi','title','type'])
        aw.writerow(['orcid','affiliation_type','org_name','city','country','org_id','org_source'])
        tar = tarfile.open(src, mode='r|gz')
        try:
            for m in tar:
                if not (m.isfile() and m.name.endswith('.xml')):
                    continue
                try:
                    person, dois, affils = parse_record(tar.extractfile(m).read())
                except Exception:
                    continue          # skip a bad record (don't stop the whole run)
                pw.writerow(person)
                for d in dois:
                    ww.writerow([person[0], d[0], d[1], d[2]])
                for a in affils:
                    aw.writerow([person[0], *a])
                n += 1
                if n % 1000000 == 0:
                    print(f'  ...{n:,} records', file=sys.stderr, flush=True)
                if cap and n >= cap:
                    break
        except Exception as e:
            print(f'stream ended after {n:,} records: {e}', file=sys.stderr)
    print(f'parsed {n} records')

if __name__ == '__main__':
    main()
