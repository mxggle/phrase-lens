import Foundation

/// The plain text behind an answer, as it should be read aloud.
///
/// Markdown markers are punctuation for the eye: a speech engine says them, so
/// a dictionary entry read straight from the pane comes back as "asterisk
/// asterisk". What reaches the synthesizer is the prose with the markup taken
/// back out and the blocks nobody wants spoken left behind.
enum SpokenText {
  static func from(_ text: String, isMarkdown: Bool) -> String {
    guard isMarkdown else { return text }
    return MarkdownParser.parse(text).compactMap(spoken).joined(separator: "\n")
  }

  private static func spoken(_ block: MarkdownBlock) -> String? {
    switch block {
    case .heading(_, let text), .paragraph(let text), .quote(let text):
      return plain(text)
    case .unorderedList(let items):
      return items.map(plain).joined(separator: "\n")
    case .orderedList(_, let items):
      return items.map(plain).joined(separator: "\n")
    case .table(_, let rows):
      // The cells carry the entry; the header row is a label for the eye.
      return rows.map { $0.map(plain).joined(separator: ", ") }.joined(separator: "\n")
    // A code block is not language anyone is trying to pronounce, and a rule
    // is a line on a page.
    case .code, .divider:
      return nil
    }
  }

  private static func plain(_ markdown: String) -> String {
    let attributed =
      (try? AttributedString(
        markdown: markdown,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      )) ?? AttributedString(markdown)
    return String(attributed.characters)
  }
}
