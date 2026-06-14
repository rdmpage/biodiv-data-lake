#!/usr/bin/env python3
"""Stream-parse the Zenodo metadata dump (records-xml.tar.gz, OAI-DataCite XML)
into normalised TSVs, keeping only records in the target communities. Stdlib only
(tarfile + xml.etree). Run from the repo root via zenodo/build_parquet.sh, or:

  python3 zenodo/parse_records.py <records-xml.tar.gz> <out_prefix> [community,community,...]

Default communities: biosyslit,bionomia. Emits five TSVs (then build_parquet.sh
-> Parquet):
  <p>_record.tsv      zenodo_id, doi, doi_is_zenodo, version_of, resource_type,
                      resource_subtype, title, date, year, publisher, license,
                      open_access, community, issn, plazi_lsid
  <p>_creator.tsv     zenodo_id, seq, name, given, family, orcid, affiliation
  <p>_related.tsv     zenodo_id, relation, id_type, resource_type, value, doi
  <p>_subject.tsv     zenodo_id, subject
  <p>_description.tsv zenodo_id, description_type, text   (whitespace collapsed)

Speed: a byte-substring pre-filter skips the ~millions of non-matching records
before any XML parse, so only the target-community slice is actually parsed.
Records are OAI-DataCite-wrapped (<oai_datacite><payload><resource>...); parsing
is by local tag name so the namespaces don't matter. Prototype lineage: the ORCID
parser in ../orcid/parse_summaries.py.
"""
import sys, re, tarfile, csv
import xml.etree.ElementTree as ET

def local(tag):
    return tag.rsplit('}', 1)[-1]

def clean(s):
    return ' '.join(s.split()) if s else ''

def find(el, *path):                 # descendants matching a local-name path
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

ORCID_RE = re.compile(r'(\d{4}-\d{4}-\d{4}-\d{3}[\dxX])')
COMM_RE  = re.compile(r'zenodo\.org/communities/([^/]+)')

def get_resource(root):
    if local(root.tag) == 'resource':
        return root
    hits = find(root, 'payload', 'resource')
    if hits:
        return hits[0]
    for e in root.iter():
        if local(e.tag) == 'resource':
            return e
    return None

def parse(resource):
    R = resource
    # identifiers
    zid = ''
    for ai in find(R, 'alternateIdentifiers', 'alternateIdentifier'):
        if ai.get('alternateIdentifierType') == 'oai' and ai.text:
            zid = ai.text.strip().replace('oai:zenodo.org:', '')
    doi = ''
    for idn in find(R, 'identifier'):
        if idn.get('identifierType') == 'DOI' and idn.text:
            doi = idn.text.strip().lower()
    rtype = (find(R, 'resourceType')[0].get('resourceTypeGeneral', '') if find(R, 'resourceType') else '')
    rsub  = text1(R, 'resourceType')
    title = text1(R, 'titles', 'title')
    year  = text1(R, 'publicationYear')
    date  = year
    for d in find(R, 'dates', 'date'):
        if d.get('dateType') == 'Issued' and d.text:
            date = clean(d.text)
    publisher = text1(R, 'publisher')
    license_ = open_access = ''
    for r in find(R, 'rightsList', 'rights'):
        if r.get('rightsIdentifier') and not license_:
            license_ = r.get('rightsIdentifier')
        if 'openaccess' in (r.get('rightsURI') or '').lower():
            open_access = 'true'
    plazi_lsid = ''
    for ai in find(R, 'alternateIdentifiers', 'alternateIdentifier'):
        if ai.get('alternateIdentifierType') == 'LSID' and ai.text:
            plazi_lsid = ai.text.strip()
    # related identifiers + derived fields (communities, issn, version_of)
    related, communities, issn, version_of = [], [], '', ''
    for ri in find(R, 'relatedIdentifiers', 'relatedIdentifier'):
        rel  = ri.get('relationType', '')
        idt  = ri.get('relatedIdentifierType', '')
        rtg  = ri.get('resourceTypeGeneral', '')
        val  = clean(ri.text)
        if not val:
            continue
        related.append((rel, idt, rtg, val, val.lower() if idt == 'DOI' else ''))
        if idt == 'URL' and rel == 'IsPartOf':
            m = COMM_RE.search(val)
            if m:
                communities.append(m.group(1))
        if idt == 'ISSN' and rel == 'IsPartOf' and not issn:
            issn = val
        if idt == 'DOI' and rel == 'IsVersionOf' and not version_of:
            version_of = val.lower()
    creators = []
    for i, c in enumerate(find(R, 'creators', 'creator')):
        orcid = ''
        for ni in find(c, 'nameIdentifier'):
            if (ni.get('nameIdentifierScheme') or '').upper() == 'ORCID' and ni.text:
                m = ORCID_RE.search(ni.text)
                if m:
                    orcid = m.group(1).upper()
        creators.append((i, text1(c, 'creatorName'), text1(c, 'givenName'),
                         text1(c, 'familyName'), orcid, text1(c, 'affiliation')))
    subjects = [clean(s.text) for s in find(R, 'subjects', 'subject') if s.text and s.text.strip()]
    descriptions = [(d.get('descriptionType', ''), clean(d.text))
                    for d in find(R, 'descriptions', 'description') if d.text and d.text.strip()]
    rec = (zid, doi, 'true' if doi.startswith('10.5281/zenodo.') else 'false',
           version_of, rtype, rsub, title, date, year, publisher, license_,
           open_access, ';'.join(communities), issn, plazi_lsid)
    return zid, communities, rec, creators, related, subjects, descriptions

def main():
    src, prefix = sys.argv[1], sys.argv[2]
    targets = set((sys.argv[3] if len(sys.argv) > 3 else 'biosyslit,bionomia').split(','))
    needles = [t.encode() for t in targets]
    kept = seen = 0
    out = {k: csv.writer(open(f'{prefix}_{k}.tsv', 'w', newline=''), delimiter='\t')
           for k in ('record', 'creator', 'related', 'subject', 'description')}
    out['record'].writerow(['zenodo_id','doi','doi_is_zenodo','version_of','resource_type',
        'resource_subtype','title','date','year','publisher','license','open_access',
        'community','issn','plazi_lsid'])
    out['creator'].writerow(['zenodo_id','seq','name','given','family','orcid','affiliation'])
    out['related'].writerow(['zenodo_id','relation','id_type','resource_type','value','doi'])
    out['subject'].writerow(['zenodo_id','subject'])
    out['description'].writerow(['zenodo_id','description_type','text'])
    tar = tarfile.open(src, mode='r|gz')
    try:
        for m in tar:
            if not (m.isfile() and m.name.endswith('.xml')):
                continue
            seen += 1
            if seen % 1000000 == 0:
                print(f'  ...scanned {seen:,}, kept {kept:,}', file=sys.stderr, flush=True)
            data = tar.extractfile(m).read()
            if not any(n in data for n in needles):     # cheap pre-filter
                continue
            try:
                R = get_resource(ET.fromstring(data))
                if R is None:
                    continue
                zid, comms, rec, creators, related, subjects, descs = parse(R)
            except Exception:
                continue
            if not (set(comms) & targets) or not zid:    # confirm membership
                continue
            kept += 1
            out['record'].writerow(rec)
            for c in creators:    out['creator'].writerow([zid, *c])
            for r in related:     out['related'].writerow([zid, *r])
            for s in subjects:    out['subject'].writerow([zid, s])
            for dt, tx in descs:  out['description'].writerow([zid, dt, tx])
    except Exception as e:
        print(f'stream ended after {seen:,} scanned: {e}', file=sys.stderr)
    print(f'scanned {seen} records, kept {kept}')

if __name__ == '__main__':
    main()
