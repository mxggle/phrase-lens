#!/usr/bin/env python3
"""Report real pack coverage without turning absence into generated content."""
import json,pathlib,sqlite3
ROOT=pathlib.Path(__file__).resolve().parents[2]
PACKS=ROOT/'Sources/PhraseLens/Resources/Dictionaries'
QUERIES={'ja':['食べる','食べました','お疲れ様','こんにちは','はし','橋','猫','必要','大丈夫','嬉しい','取り戻す','生','ｶﾀｶﾅ'],
         'en':['hello','bank','run','running','went','go','take it easy','dictionary','reliable','extensible','cat','learn']}
from build_pack import key


def audit():
    databases=[(json.loads(p.read_text()),sqlite3.connect(p.with_suffix('.sqlite'))) for p in sorted(PACKS.glob('*.json'))]
    report={}
    for language,queries in QUERIES.items():
        rows=[]
        for query in queries:
            terms={key(query)}
            if language=='en':terms.add(key(query).lower())
            if language=='ja':
                terms.add(''.join(chr(ord(c)-0x60) if '\u30a1'<=c<='\u30f6' else c for c in key(query)))
                for suffix in ['ませんでした','ました','ません']:
                    if query.endswith(suffix):terms.add(query[:-len(suffix)]+'ます')
            hits=[]
            for manifest,db in databases:
                for term in sorted(terms):
                    for row in db.execute('SELECT DISTINCT e.payload FROM forms f JOIN entries e ON f.entry_id=e.id WHERE f.language=? AND f.term=?',(language,term)):
                        entry=json.loads(row[0])
                        hits.append((manifest['id'],entry['headword']))
            rows.append(dict(query=query,found=bool(hits),headwords=sorted(set(x[1] for x in hits)),sources=sorted(set(x[0] for x in hits))))
        report[language]=dict(found=sum(x['found'] for x in rows),total=len(rows),queries=rows)
    for _,db in databases:db.close()
    return report

if __name__=='__main__':print(json.dumps(audit(),ensure_ascii=False,indent=2))
