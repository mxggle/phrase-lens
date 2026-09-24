#!/usr/bin/env python3
"""Build the learner core of ECDICT (exam-tagged or top-50k frequency words).
Pass --all to build all entries instead. This importer never splits a source
line into invented senses, and retains ECDICT's word-form relationships.
"""
import argparse,csv,hashlib,json,os,pathlib,sqlite3
from urllib.parse import quote
from build_pack import key, sha256_file


def build(source, output, revision, include_all=False):
    output=pathlib.Path(output)
    output.parent.mkdir(parents=True,exist_ok=True)
    temporary=output.with_suffix('.building.sqlite')
    if temporary.exists(): temporary.unlink()
    db=sqlite3.connect(temporary)
    db.executescript('''PRAGMA user_version=1;
      CREATE TABLE entries(id TEXT PRIMARY KEY,language TEXT NOT NULL,payload TEXT NOT NULL);
      CREATE TABLE forms(language TEXT NOT NULL,term TEXT NOT NULL,entry_id TEXT NOT NULL,kind TEXT NOT NULL,
        PRIMARY KEY(language,term,entry_id,kind)) WITHOUT ROWID;
      CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    ''')
    count=0
    with open(source,encoding='utf-8-sig',newline='') as stream:
      for row in csv.DictReader(stream):
        keep=bool(row['tag'] or row['oxford']=='1' or row['collins']) or any(0<int(row[k] or 0)<=50000 for k in ['bnc','frq'])
        if not include_all and not keep: continue
        word=row['word'].strip()
        lines=[s.strip() for s in row['translation'].replace('\\n','\n').splitlines() if s.strip()]
        if not word or not lines:continue
        entry_id=hashlib.sha256(word.encode()).hexdigest()[:24]
        entry=dict(id=entry_id,headword=word,sourceLanguage='en',definitionLanguage='zh',readings=[],
          partOfSpeech=None,senses=[dict(id='0',glosses=lines,labels=[])],
          sourceURL=f'https://github.com/skywind3000/ECDICT/blob/{revision}/ecdict.csv')
        db.execute('INSERT OR IGNORE INTO entries VALUES(?,?,?)',(entry_id,'en',json.dumps(entry,ensure_ascii=False,separators=(',',':'))))
        forms=[(word,'headword')]
        for exchange in row['exchange'].split('/'):
          if ':' in exchange:
            kind,value=exchange.split(':',1)
            # 0 refers to another lemma, not an inflection of this headword.
            if kind in ['p','d','i','3','s','r','t'] and value:forms.append((value,'form'))
        for form,kind in forms:
          for variant in {key(form),key(form).lower()}:
            db.execute('INSERT OR IGNORE INTO forms VALUES(?,?,?,?)',('en',variant,entry_id,kind))
        count+=1
    checksum=sha256_file(source)
    manifest=dict(schemaVersion=1,id='ecdict-zh',name='ECDICT 英汉词典',revision=revision,
      sourceLanguages=['en'],definitionLanguages=['zh'],attribution='ECDICT · skywind3000 and contributors',
      license='MIT',licenseURL=f'https://github.com/skywind3000/ECDICT/blob/{revision}/LICENSE',
      canPersist=True,canUseWithAI=True,sourceSHA256=checksum,
      sourceURL=f'https://github.com/skywind3000/ECDICT/blob/{revision}/ecdict.csv',
      entries=count,selection='all' if include_all else 'exam-tagged, Oxford, Collins-rated, or BNC/FRQ rank <= 50000')
    db.execute('INSERT INTO metadata VALUES(?,?)',('manifest',json.dumps(manifest,ensure_ascii=False)))
    db.commit()
    assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    db.execute('VACUUM');db.close()
    os.replace(temporary,output)
    output.with_suffix('.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(manifest,ensure_ascii=False,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source');p.add_argument('output');p.add_argument('--revision',required=True)
    p.add_argument('--all',action='store_true')
    a=p.parse_args();build(a.source,a.output,a.revision,a.all)
