#!/usr/bin/env python3
"""Build a deterministic, indexed Chinese-gloss pack from raw Wiktextract JSONL.

No network calls: pass a downloaded .jsonl[.gz], its dump date, and output path.
Only dictionary glosses are retained; quotations/audio have separate rights and
are intentionally excluded. Original scripts and entry boundaries are preserved.
"""
import argparse, collections, gzip, hashlib, json, os, pathlib, sqlite3, unicodedata
from urllib.parse import quote


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def key(text):
    # Width normalization for search only; displayed headwords stay untouched.
    return unicodedata.normalize('NFKC', text).strip()


def reading(form):
    value = form.get('form', '')
    for written, kana in form.get('ruby', []):
        value = value.replace(written, kana, 1)
    return value if form.get('ruby') else None


def build(source, output, dump_date, languages):
    output = pathlib.Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix('.building.sqlite')
    if temporary.exists():
        temporary.unlink()
    db = sqlite3.connect(temporary)
    db.executescript('''
      PRAGMA user_version=1;
      CREATE TABLE entries(id TEXT PRIMARY KEY, language TEXT NOT NULL, payload TEXT NOT NULL);
      CREATE TABLE forms(language TEXT NOT NULL, term TEXT NOT NULL, entry_id TEXT NOT NULL,
                         kind TEXT NOT NULL, PRIMARY KEY(language,term,entry_id,kind)) WITHOUT ROWID;
      CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    ''')
    stats = collections.Counter()
    links = []
    opener = gzip.open if str(source).endswith('.gz') else open
    with opener(source, 'rt', encoding='utf-8') as stream:
        for line in stream:
            raw = json.loads(line)
            lang, word = raw.get('lang_code'), raw.get('word', '').strip()
            if lang not in languages or not word:
                continue
            stats[lang + '_source_records'] += 1
            for target in raw.get('redirects', []):
                if isinstance(target, str): links.append((lang, word, target))
            senses = []
            for sense in raw.get('senses', []):
                for relationship in ('form_of',):
                    for target in sense.get(relationship, []):
                        if target.get('word'):
                            links.append((lang, word, target['word']))
                glosses = [x.strip() for x in sense.get('glosses', []) if x.strip()]
                if not glosses or 'no-gloss' in sense.get('tags', []):
                    continue
                # Unknown-POS soft redirects are not usable definitions.
                if raw.get('pos') in ('unknown', 'soft-redirect', 'character'):
                    continue
                senses.append(dict(id=str(len(senses)), glosses=glosses,
                                   labels=sense.get('raw_tags', []) + sense.get('tags', [])))
            if not senses:
                stats[lang + '_without_definition'] += 1
                continue
            readings = list(dict.fromkeys(filter(None, (reading(f) for f in raw.get('forms', [])
                                                        if f.get('form') == word))))
            # Same page may contain several pronunciations/POS/etymologies. A
            # content ID prevents accidentally merging their unrelated senses.
            identity = json.dumps([lang, word, raw.get('pos'), readings, senses], ensure_ascii=False,
                                  sort_keys=True, separators=(',', ':'))
            entry_id = hashlib.sha256(identity.encode()).hexdigest()[:24]
            entry = dict(id=entry_id, headword=word, sourceLanguage=lang, definitionLanguage='zh',
                         readings=readings, partOfSpeech=raw.get('pos_title') or raw.get('pos'),
                         senses=senses, sourceURL='https://zh.wiktionary.org/wiki/' + quote(word, safe=''))
            payload = json.dumps(entry, ensure_ascii=False, separators=(',', ':'))
            inserted = db.execute('INSERT OR IGNORE INTO entries VALUES(?,?,?)', (entry_id,lang,payload)).rowcount
            stats[lang + '_entries'] += inserted
            forms = [(word, 'headword')] + [(r,'reading') for r in readings]
            for f in raw.get('forms', []):
                allowed = {'canonical','alternative','plural','singular','past','present','participle',
                           'third-person','comparative','superlative','continuative','formal','negative'}
                is_form = bool(allowed.intersection(f.get('tags', []))) or f.get('source') == 'inflection table'
                # 'forms' also contains Japanese counters and other metadata;
                # a counter such as 匹 must never become an alias for 猫.
                if is_form and f.get('form') and f['form'] != word and len(f['form']) <= 80:
                    forms.append((f['form'], 'form'))
                    if f.get('hiragana'): forms.append((f['hiragana'], 'form'))
            for term, kind in forms:
                variants = [key(term)]
                if lang == 'en':
                    variants.append(key(term).lower())
                if lang == 'ja':
                    variants.append(''.join(chr(ord(c)-0x60) if '\u30a1' <= c <= '\u30f6' else c for c in key(term)))
                for variant in set(variants):
                    db.execute('INSERT OR IGNORE INTO forms VALUES(?,?,?,?)', (lang,variant,entry_id,kind))
    # Resolve source-provided inflection/alternate-form relationships, bounded
    # to three hops. Do not synthesize meanings for unresolved redirects.
    for _ in range(3):
        for lang, alias, target in links:
            db.execute('INSERT OR IGNORE INTO forms SELECT language,?,entry_id,? FROM forms '
                       'WHERE language=? AND term=?', (key(alias),'form',lang,key(target)))
    checksum = sha256_file(source)
    manifest = dict(schemaVersion=1, id='wiktionary-zh', name='中文维基词典',
                    revision=dump_date + '-' + checksum[:12], sourceLanguages=sorted(languages),
                    definitionLanguages=['zh'], attribution='中文维基词典 contributors · extracted by Wiktextract / Kaikki',
                    license='CC BY-SA 4.0', licenseURL='https://creativecommons.org/licenses/by-sa/4.0/',
                    sourceURL='https://kaikki.org/zhwiktionary/rawdata.html', sourceSHA256=checksum,
                    dumpDate=dump_date, canPersist=True, canUseWithAI=True, statistics=dict(stats))
    db.execute('INSERT INTO metadata VALUES(?,?)', ('manifest',json.dumps(manifest,ensure_ascii=False)))
    db.commit()
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    db.execute('VACUUM')
    db.close()
    os.replace(temporary, output)
    output.with_suffix('.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(manifest,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    parser.add_argument('--dump-date', required=True)
    parser.add_argument('--languages', nargs='+', default=['ja','en'])
    args = parser.parse_args()
    build(args.source, args.output, args.dump_date, args.languages)
