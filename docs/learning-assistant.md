# Learning assistant

PhraseLens keeps a study record of what the reader looks up and uses it to
explain better, schedule review, and diagnose where study is stuck. This
document records the design and its acceptance boundaries. It is macOS only;
the iOS app does not keep history.

## The record

`learning.json` sits beside `history.json` and outlives the history cap. Each
`LearningTerm` is one word or short phrase with every sitting the reader had
with it (`LearningEncounter`): when, the spelling, the sentence it was met in,
the actions run, the follow-up questions asked, and the sense met there.

- A history row counts as a lookup when its text is a word or short phrase
  (`PromptBuilder.isLikelyShortPhrase`) under an action that studies it. Polish,
  Summarize, and Explain Code do not count.
- Spellings are compared by `LearningLedger.key`: case and width fold away,
  accents and kana voicing do not.
- Lemmas come from the system lemmatizer where it covers the language. Every
  other language-specific judgement — dictionary forms it does not cover,
  readings, senses — is the annotator's.
- Lookups within 30 minutes of each other are one sitting. A term met in two
  sittings is a repeat; three sittings on more than one day is "not sticking".
- History that predates the record is filed once, on first launch. Repeats
  found there join review ten a day, the ones that are not sticking first.
- Deleting history deletes what was filed from it. The history cap does not.

## Using the record

- **Memory in explanations.** Definition, Explain Usage, Explain in Context,
  Analyze, and Compare Synonyms receive an escaped `<untrusted-learner-memory>`
  block: earlier sentences and senses, earlier questions, related terms, the
  memory card's hook, and what the reader usually asks for. Translate and
  writing replacement never receive it.
- **Adaptive first answer.** A follow-up subject asked at least three times and
  in a quarter of all questions is requested in the first answer, and the
  follow-up chips are ordered by how often each is used.
- **Lookup badge.** The result pane and the pop-up show how often the term on
  screen was looked up, opening its record in a popover.
- **Review.** Repeats are enrolled automatically, first due the next day. The
  schedule is a small SM-2 variant; looking a term up again on a later day is a
  lapse the reader did not have to grade.

## Background analysis

Runs through the default AI connection, unattended and bounded (two batches of
twelve terms twenty seconds after lookups settle), or on request with progress.

- **Annotator.** The ledger proposes related pairs locally — shared stems,
  near spellings, shared Han characters, and the system word embedding where it
  exists — and the model judges only those. A lemma that reveals two terms are
  one merges them and repoints relations.
- **Memory cards** for terms that are not sticking, built from the sentences the
  reader met them in.
- **Weekly diagnosis** once a week when there are at least ten lookups or
  passages, or on request. Issues cite term labels; labels not in the record are
  dropped.
- **Auto-collect** saves a term that is not sticking to Vocabulary once.

## Study assistant

A chat in Study → Assistant that reads the record through tools before it
answers: `search_terms`, `get_term`, `search_history`, `get_stats`,
`get_report`, `add_to_review`, `save_to_vocabulary`, and — when allowed —
`find_related_words` (Datamuse) and `dictionary_lookup` (Free Dictionary), which
send one English word and nothing else.

Tool calling is native for Anthropic Messages and OpenAI Chat Completions; the
request is built by the translation request builders and only its messages,
tools, and streaming flag are rewritten, so provider quirks carry over. Claude
thinking blocks are echoed back verbatim. Gemini, Ollama, Cohere, and ChatGPT
OAuth describe the tools in the prompt and answer with a JSON object instead.
Each question allows six rounds of tool calls before the assistant must answer.

## Settings

Study settings: keep the record, use it in explanations, analyze
automatically, collect words that will not stick, and allow the dictionary
APIs. All default on. Clearing the record keeps history and Vocabulary.

## Verification

`SelfTestRunner` covers the ledger, memory prompts, habits, relation
candidates, annotator and coach request and reply shapes, the scheduler, both
native tool protocols and the prompt-described one, and every tool. In DEBUG,
`--learning-probe <library> <defaults-suite> <credentials-dir>
analyze|report|ask` drives the model-backed work end to end against copies, and
`--preview-learning-tab`, `--preview-learning-term`,
`--preview-learning-popover`, and `--preview-assistant` put the UI in
deterministic states for screenshots.
