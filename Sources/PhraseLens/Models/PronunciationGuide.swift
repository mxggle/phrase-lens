import Foundation

/// Which term in an answer a reading is attached to.
///
/// A reader needs two different things from one answer: how to say the term
/// they selected, in the language they are reading, and how to say the term
/// they got back, in the language they are learning to speak. The reading
/// systems are the source and target languages' own, so the two are separate
/// annotations that happen to follow the same policy.
enum PronunciationSubject: Sendable {
  case sourceTerm
  case translation

  /// How the instruction names this term mid-sentence.
  var name: String {
    switch self {
    case .sourceTerm: "the selected source term"
    case .translation: "the translation"
    }
  }

  var title: String {
    switch self {
    case .sourceTerm: "The selected source term"
    case .translation: "The translation"
    }
  }

  /// Where in the answer the annotation goes. The source term is named up
  /// front, since the answer is about it; the translation is annotated where
  /// it first appears, because in a plain translation that is the whole
  /// answer and in a dictionary entry it is one line inside it.
  var placement: String {
    switch self {
    case .sourceTerm: "At the start of the answer, name that term once as"
    case .translation: "The first time that term appears in the answer, write it as"
    }
  }

  var counterpart: PronunciationSubject {
    switch self {
    case .sourceTerm: .translation
    case .translation: .sourceTerm
    }
  }
}

/// A language-specific reading aid: how a term in that language is written so
/// a learner can pronounce it, and how a correct reading is arrived at.
///
/// Keeping these policies in a registry makes pronunciation a language
/// capability instead of an Action special case. A new language can opt in
/// without changing `PromptBuilder` or the Translate/Explain in Context modes,
/// and the same policy serves whichever side of the translation is being read.
struct PronunciationGuide: Sendable {
  /// The reading system, named as the instruction refers to it.
  let script: String
  /// The shape of one annotation, with examples of it.
  let notation: String
  /// How a reading is resolved. Deliberately says nothing about which term is
  /// being annotated: getting a reading right is the same work on either side
  /// of the translation.
  let accuracy: String

  /// The policy for annotating one term.
  ///
  /// `paired` is the other annotated term, when the answer carries two
  /// readings. Naming it matters: with only one side annotated, the other
  /// side is a place readings must not appear, and saying so is what keeps a
  /// gloss out of prose the reader did not ask to have annotated.
  func instruction(for subject: PronunciationSubject, paired: Bool) -> String {
    let unannotated = paired ? "" : "\(subject.counterpart.name), "
    return """
      \(subject.title) needs one \(script) reading aid. \(subject.placement) \(notation). \
      Never type the backticks; they mark the shape only. Annotate only \(subject.name). \
      Never add readings to \(unannotated)the explanation, headings, examples, or quoted \
      source material.

      \(accuracy)
      """
  }
}

extension LanguageCode {
  /// Reading systems that are useful for a learner and have an unambiguous,
  /// compact inline representation. Languages whose ordinary spelling already
  /// exposes the reading do not opt in merely to produce noisy romanization.
  var pronunciationGuide: PronunciationGuide? {
    Self.pronunciationGuides[rawValue]
  }

  private static let pronunciationGuides: [String: PronunciationGuide] = [
    LanguageCode.japanese.rawValue: PronunciationGuide(
      script: "Japanese",
      notation: """
        `表記（よみ）`, with the complete lexical reading in hiragana; for example \
        `今日（きょう）` or `食べる（たべる）`
        """,
      accuracy: """
        Pronunciation accuracy is mandatory. Silently resolve the reading from the complete \
        word, its meaning and inflection, and the supplied surrounding context before writing \
        it. Never derive a reading one kanji at a time. Check contextual readings, counters, \
        rendaku, compounds, okurigana, and proper names as applicable. If the context does not \
        determine a genuinely ambiguous or uncommon proper-name reading, do not guess: say in \
        the answer language that more context is required. In a dictionary entry, multiple \
        readings are allowed only when each is explicitly tied to its distinct sense.
        """
    ),
    LanguageCode.simplifiedChinese.rawValue: Self.mandarinPronunciationGuide,
    LanguageCode.traditionalChinese.rawValue: Self.mandarinPronunciationGuide,
  ]

  private static let mandarinPronunciationGuide = PronunciationGuide(
    script: "Mandarin",
    notation: """
      `词语（pīnyīn）`, using standard Hanyu Pinyin with tone marks, not tone numbers
      """,
    accuracy: """
      Pronunciation accuracy is mandatory. Silently resolve every polyphonic character from the \
      complete word, its meaning, and the supplied surrounding context before writing it. Never \
      transliterate characters independently. Follow standard Hanyu Pinyin orthography for \
      written tone changes; do not rewrite every phonetic tone sandhi. If the context does not \
      determine a genuinely ambiguous or uncommon proper-name reading, do not guess: say in the \
      answer language that more context is required. In a dictionary entry, multiple readings \
      are allowed only when each is explicitly tied to its distinct sense.
      """
  )
}
