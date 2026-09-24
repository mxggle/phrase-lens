# Dictionary data and reproducible builds

PhraseLens bundles offline Japanese-to-Chinese and English-to-Chinese dictionaries.
Definitions come from published dictionary records, never an AI translation of an
English gloss. Chinese script is preserved as published (traditional, simplified,
or mixed); the UI therefore labels it `中文（原文）`, not simplified Chinese.

## Bundled sources

| Pack | Snapshot | Usable entries | License |
| --- | --- | ---: | --- |
| Chinese Wiktionary, extracted by Wiktextract / Kaikki | Wikimedia dump 2026-09-01, extraction downloaded 2026-09-21 | Japanese 44,587; English 58,747 | CC BY-SA 4.0 |
| ECDICT learner core | Commit `bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b` | English 59,137 | Repository MIT license |

Entry counts include distinct readings and parts of speech; they are not counts
of unique headwords. The pack manifests record full source checksums, revisions,
language capabilities, attribution and import statistics. The ECDICT learner
core selects exam-tagged, Oxford, Collins-rated or BNC/FRQ top-50,000 entries.
Its repository describes a compilation from several sources; the upstream license
is retained, not an independent guarantee of every upstream contribution's provenance.

Sources: [Kaikki raw extraction](https://kaikki.org/zhwiktionary/rawdata.html),
[ECDICT](https://github.com/skywind3000/ECDICT),
[Wikimedia terms](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use),
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

The Wiktionary-derived database remains CC BY-SA 4.0; the ECDICT pack retains MIT.
These data licenses are separate from the application's code license. Each card
and copied entry carries attribution, a source link and a license link. Original
Wiktionary page histories identify contributors. `ATTRIBUTION.txt` and the ECDICT
license travel with the bundled resources.

## Content audit and limitations

The checked-in [audit report](DICTIONARY_DATA_AUDIT.json) is a small, deliberately
selected smoke sample, **not an estimate of overall dictionary coverage**:

- Japanese: 10 of 13 queries return entries. `食べる`, `食べました`, `お疲れ様`,
  `こんにちは`, `はし` and half-width `ｶﾀｶﾅ` work. `橋`, `取り戻す` and `生`
  have no usable definitions in this pack.
- English: 11 of 12 queries return entries across the two sources, including
  `hello`, `running`, `went` and `extensible`. `take it easy` is absent.
- Semantic regression checks verify Chinese meanings for `食べる`, `食べました`,
  `hello`, `running` and `went`; hit counts alone do not establish correctness.

Japanese coverage is limited, including gaps in common vocabulary. This is a
working first offline source, not a comprehensive Japanese dictionary. A richer
licensed Japanese-to-Chinese source is a future provider integration. No missing
entry is silently replaced by AI. Users can try a dictionary form, override the
language or explicitly request an AI explanation.

The importer excludes missing glosses, unknown-POS/soft-redirect placeholders,
and character entries whose extracted gloss is often only a school-grade heading.
It follows source redirects and inflection relationships but never generates a
missing meaning. Separate readings/POS retain separate entries. Japanese counters
are not treated as word forms. Quotations, examples, audio and images are excluded.
ECDICT translation lines remain together rather than being split into invented senses.

Japanese processing handles width/kana aliases and a few polite-tense reductions
to forms indexed from the source. It is not a full morphological analyzer. English
irregular forms use source-provided mappings. Short-word language detection is
ambiguous; the UI offers an override and labels each result's actual language.

## Rebuild

Python 3.9+ and SQLite are sufficient; the importers have no network dependency.
Download and retain the raw JSONL gzip linked from Kaikki's raw-data page and
`ecdict.csv` from the exact ECDICT commit above. Kaikki's live download changes;
verify the snapshot hash before claiming a byte-equivalent rebuild.

Expected raw SHA-256 values:

```text
zhwiktionary.jsonl.gz  824207e0d50a1e55983ba817639490ec47ed337720e4452b5d421b047bebf43c
ecdict.csv            1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf
```

From the repository root (raw sources can stay under ignored `.build`):

```sh
python3 scripts/dictionary/build_pack.py \
  .build/dictionary-sources/zhwiktionary.jsonl.gz \
  Sources/PhraseLens/Resources/Dictionaries/wiktionary-zh.sqlite \
  --dump-date 2026-09-01
python3 scripts/dictionary/build_ecdict.py \
  .build/dictionary-sources/ecdict.csv \
  Sources/PhraseLens/Resources/Dictionaries/ecdict-zh.sqlite \
  --revision bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b
python3 scripts/dictionary/audit_pack.py > docs/DICTIONARY_DATA_AUDIT.json
./scripts/test.sh
```

Importers build a temporary SQLite database, check integrity, vacuum, then replace
the output and write its manifest. Review both files together before packaging.
For updates, change the date/revision, review exclusions and the coverage report,
verify Chinese glosses and source links, then run the same tests. There is no
runtime downloader; packs update with the app. `--all` on the ECDICT importer
includes its entire dataset instead of the bundled learner subset.

## Pack contract

Schema version 1 has `entries(id, language, payload)`, indexed
`forms(language, term, entry_id, kind)` and `metadata(key, value)`. The `manifest`
metadata value must match the adjacent JSON descriptor. Payloads decode as
`DictionaryEntry`. Lookup binds SQL parameters and opens databases read-only on a
provider actor. Schema, descriptor and result-language mismatches are rejected.

SwiftPM copies the `Dictionaries` directory. The app packaging script puts the
SwiftPM resource bundle in `Contents/Resources`; packaged apps never fall back
to a developer's build directory when resources are missing. Verify a packaged
executable using `--dictionary-self-test`, as well as strict code-sign verification.
