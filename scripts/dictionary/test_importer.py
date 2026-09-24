import contextlib,csv,io,json,pathlib,sqlite3,tempfile,unittest
from build_ecdict import build as build_ecdict
from build_pack import build

class ImporterTests(unittest.TestCase):
    def test_readings_inflections_and_redirects_preserve_entry_boundaries(self):
        records=[
          dict(word='猫',lang_code='ja',pos='noun',forms=[
            dict(form='猫',tags=['canonical'],ruby=[['猫','ねこ']]),
            dict(form='匹',raw_tags=['量詞'])],senses=[dict(glosses=['貓'])]),
          dict(word='猫',lang_code='ja',pos='noun',forms=[
            dict(form='猫',tags=['canonical'],ruby=[['猫','ねこま']])],senses=[dict(glosses=['古語的貓'])]),
          dict(word='ネコ',lang_code='ja',pos='soft-redirect',redirects=['猫'],senses=[dict(tags=['no-gloss'])]),
          dict(word='生',lang_code='ja',pos='character',senses=[dict(glosses=['生（一年級漢字）'])]),
          dict(word='broken',lang_code='en',pos='unknown',senses=[dict(glosses=['placeholder'])]),
          dict(word='run',lang_code='en',pos='verb',forms=[dict(form='running',tags=['participle'])],senses=[dict(glosses=['跑'])]),
        ]
        with tempfile.TemporaryDirectory() as path:
            root=pathlib.Path(path);source=root/'input.jsonl';target=root/'pack.sqlite'
            source.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in records))
            with contextlib.redirect_stdout(io.StringIO()):build(source,target,'fixture',['en','ja'])
            db=sqlite3.connect(target)
            def lookup(text):
                return [json.loads(x[0]) for x in db.execute('select distinct e.payload from entries e join forms f on e.id=f.entry_id where f.term=?',(text,))]
            self.assertEqual(lookup('ねこ')[0]['senses'][0]['glosses'],['貓'])
            self.assertEqual(lookup('ねこま')[0]['senses'][0]['glosses'],['古語的貓'])
            self.assertEqual(len(lookup('ネコ')),2)
            self.assertEqual(lookup('匹'),[])
            self.assertEqual(lookup('生'),[])
            self.assertEqual(lookup('broken'),[])
            self.assertEqual(lookup('running')[0]['headword'],'run')
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0],'ok')
            db.close()

    def test_ecdict_keeps_source_lines_and_inflections_without_reverse_lemma(self):
        fields=['word','translation','tag','oxford','collins','bnc','frq','exchange']
        records=[dict(word='go',translation='v. 去\\nvi. 行走',tag='cet4',exchange='p:went/d:gone/0:going'),
                 dict(word='rarefixture',translation='稀有',exchange=''),
                 dict(word='frequencyfixture',translation='频率',bnc='42')]
        with tempfile.TemporaryDirectory() as path:
            root=pathlib.Path(path);source=root/'source.csv';target=root/'pack.sqlite'
            with source.open('w',newline='') as stream:
                writer=csv.DictWriter(stream,fieldnames=fields);writer.writeheader();writer.writerows(records)
            with contextlib.redirect_stdout(io.StringIO()):build_ecdict(source,target,'fixture')
            db=sqlite3.connect(target)
            payload=db.execute('select e.payload from entries e join forms f on e.id=f.entry_id where f.term=?',('went',)).fetchone()
            entry=json.loads(payload[0])
            self.assertEqual(entry['headword'],'go')
            self.assertEqual(entry['senses'][0]['glosses'],['v. 去','vi. 行走'])
            self.assertEqual(db.execute('select count(*) from forms where term in (?,?)',('going','rarefixture')).fetchone()[0],0)
            self.assertEqual(db.execute('select count(*) from entries').fetchone()[0],2)
            db.close()

if __name__=='__main__':unittest.main()
