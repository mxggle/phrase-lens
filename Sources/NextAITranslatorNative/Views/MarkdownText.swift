import SwiftUI

/// A small, inert Markdown renderer for model output.
///
/// `Text(AttributedString(markdown:))` applies inline styles, but it does not
/// lay out block presentation intents such as headings, lists, quotes, tables,
/// or fenced code. Splitting the document into blocks keeps those semantics
/// visible without introducing an HTML/WebView execution boundary.
struct MarkdownText: View {
  private let blocks: [MarkdownBlock]
  private let baseFontSize: Double

  @Environment(\.palette) private var palette

  init(_ markdown: String, baseFontSize: Double = 15) {
    blocks = MarkdownParser.parse(markdown)
    self.baseFontSize = baseFontSize
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 12) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      inlineText(text)
        .font(.system(size: headingSize(level), weight: .semibold))
        .padding(.top, level <= 2 ? 4 : 1)

    case .paragraph(let text):
      inlineText(text)
        .font(.system(size: baseFontSize))
        .lineSpacing(3)

    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("•")
              .font(.system(size: baseFontSize, weight: .semibold))
            inlineText(item)
              .font(.system(size: baseFontSize))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.leading, 4)

    case .orderedList(let start, let items):
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(start + offset).")
              .font(.system(size: baseFontSize, weight: .medium, design: .monospaced))
              .foregroundStyle(.secondary)
            inlineText(item)
              .font(.system(size: baseFontSize))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.leading, 4)

    case .quote(let text):
      HStack(spacing: 11) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(palette.borderStrong)
          .frame(width: 3)
        inlineText(text)
          .font(.system(size: baseFontSize))
          .foregroundStyle(palette.mutedForeground)
          .italic()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 2)

    case .code(let language, let code):
      VStack(alignment: .leading, spacing: 7) {
        if let language, !language.isEmpty {
          Text(language.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(palette.faintForeground)
        }
        ScrollView(.horizontal) {
          Text(code)
            .font(.system(size: max(12, baseFontSize - 1), design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        palette.muted,
        in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
          .strokeBorder(palette.border, lineWidth: 1)
      }

    case .table(let headers, let rows):
      // Cells wrap instead of scrolling sideways: a table nested in a scroll
      // view must never widen its container, and translated cells are short.
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
            inlineText(header)
              .font(.system(size: baseFontSize, weight: .semibold))
              .padding(9)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .background(palette.muted)

        Hairline()

        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(headers.indices, id: \.self) { column in
              inlineText(column < row.count ? row[column] : "")
                .font(.system(size: baseFontSize))
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          Hairline()
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
          .strokeBorder(palette.border, lineWidth: 1)
      }

    case .divider:
      Hairline()
        .padding(.vertical, 3)
    }
  }

  private func inlineText(_ markdown: String) -> Text {
    let attributed =
      (try? AttributedString(
        markdown: markdown,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      )) ?? AttributedString(markdown)
    return Text(attributed)
  }

  private func headingSize(_ level: Int) -> Double {
    switch level {
    case 1: baseFontSize * 1.55
    case 2: baseFontSize * 1.35
    case 3: baseFontSize * 1.18
    default: baseFontSize
    }
  }
}

enum MarkdownBlock: Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case unorderedList([String])
  case orderedList(start: Int, items: [String])
  case quote(String)
  case code(language: String?, text: String)
  case table(headers: [String], rows: [[String]])
  case divider
}

enum MarkdownParser {
  static func looksLikeMarkdown(_ text: String) -> Bool {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if fenceStart(trimmed) != nil || heading(line) != nil || isDivider(trimmed)
        || unorderedItem(line) != nil || orderedItem(line) != nil || quoteLine(line) != nil
        || (index + 1 < lines.count && line.contains("|") && isTableDivider(lines[index + 1]))
      {
        return true
      }
    }

    return hasPairedMarker("**", in: text)
      || hasPairedMarker("__", in: text)
      || hasPairedMarker("`", in: text)
      || (text.contains("[") && text.contains("]("))
  }

  static func parse(_ markdown: String) -> [MarkdownBlock] {
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [MarkdownBlock] = []
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        index += 1
        continue
      }

      if let fence = fenceStart(trimmed) {
        var codeLines: [String] = []
        index += 1
        while index < lines.count, !isClosingFence(lines[index], marker: fence.marker) {
          codeLines.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        blocks.append(.code(language: fence.language, text: codeLines.joined(separator: "\n")))
        continue
      }

      if let heading = heading(line) {
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if isDivider(trimmed) {
        blocks.append(.divider)
        index += 1
        continue
      }

      if index + 1 < lines.count,
        line.contains("|"),
        isTableDivider(lines[index + 1])
      {
        let headers = tableCells(line)
        var rows: [[String]] = []
        index += 2
        while index < lines.count {
          let candidate = lines[index]
          guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
            candidate.contains("|")
          else { break }
          rows.append(tableCells(candidate))
          index += 1
        }
        blocks.append(.table(headers: headers, rows: rows))
        continue
      }

      if unorderedItem(line) != nil {
        var items: [String] = []
        while index < lines.count, let item = unorderedItem(lines[index]) {
          items.append(item)
          index += 1
        }
        blocks.append(.unorderedList(items))
        continue
      }

      if let first = orderedItem(line) {
        var items = [first.text]
        index += 1
        while index < lines.count, let item = orderedItem(lines[index]) {
          items.append(item.text)
          index += 1
        }
        blocks.append(.orderedList(start: first.number, items: items))
        continue
      }

      if quoteLine(line) != nil {
        var quoteLines: [String] = []
        while index < lines.count, let content = quoteLine(lines[index]) {
          quoteLines.append(content)
          index += 1
        }
        blocks.append(.quote(quoteLines.joined(separator: "\n")))
        continue
      }

      var paragraphLines = [trimmed]
      index += 1
      while index < lines.count, !startsBlock(lines, at: index) {
        paragraphLines.append(lines[index].trimmingCharacters(in: .whitespaces))
        index += 1
      }
      blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
    }

    return blocks
  }

  private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
    let line = lines[index]
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || fenceStart(trimmed) != nil || heading(line) != nil
      || isDivider(trimmed) || unorderedItem(line) != nil || orderedItem(line) != nil
      || quoteLine(line) != nil
    {
      return true
    }
    return index + 1 < lines.count && line.contains("|") && isTableDivider(lines[index + 1])
  }

  private static func heading(_ line: String) -> (level: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let level = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level) else { return nil }
    let boundary = trimmed.index(trimmed.startIndex, offsetBy: level)
    guard boundary < trimmed.endIndex, trimmed[boundary].isWhitespace else { return nil }
    var text = trimmed[boundary...].trimmingCharacters(in: .whitespaces)
    while text.last == "#" { text.removeLast() }
    return (level, text.trimmingCharacters(in: .whitespaces))
  }

  private static func unorderedItem(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2, ["-", "*", "+"].contains(String(trimmed.first!)) else {
      return nil
    }
    let second = trimmed.index(after: trimmed.startIndex)
    guard trimmed[second].isWhitespace else { return nil }
    return trimmed[second...].trimmingCharacters(in: .whitespaces)
  }

  private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.prefix(while: { $0.isNumber })
    guard let number = Int(digits), !digits.isEmpty else { return nil }
    var boundary = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
    guard boundary < trimmed.endIndex, trimmed[boundary] == "." || trimmed[boundary] == ")" else {
      return nil
    }
    boundary = trimmed.index(after: boundary)
    guard boundary < trimmed.endIndex, trimmed[boundary].isWhitespace else { return nil }
    return (number, trimmed[boundary...].trimmingCharacters(in: .whitespaces))
  }

  private static func quoteLine(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.first == ">" else { return nil }
    return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
  }

  private static func fenceStart(_ line: String) -> (marker: String, language: String?)? {
    let marker: String
    if line.hasPrefix("```") {
      marker = "```"
    } else if line.hasPrefix("~~~") {
      marker = "~~~"
    } else {
      return nil
    }
    let language = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
    return (marker, language.isEmpty ? nil : language)
  }

  private static func isClosingFence(_ line: String, marker: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
  }

  private static func isDivider(_ line: String) -> Bool {
    let compact = line.filter { !$0.isWhitespace }
    guard compact.count >= 3, let first = compact.first, ["-", "_", "*"].contains(first) else {
      return false
    }
    return compact.allSatisfy { $0 == first }
  }

  private static func isTableDivider(_ line: String) -> Bool {
    let cells = tableCells(line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
      let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      return core.count >= 3 && core.allSatisfy { $0 == "-" }
    }
  }

  private static func tableCells(_ line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.first == "|" { trimmed.removeFirst() }
    if trimmed.last == "|" { trimmed.removeLast() }
    return trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  private static func hasPairedMarker(_ marker: String, in text: String) -> Bool {
    guard let first = text.range(of: marker) else { return false }
    return text[first.upperBound...].contains(marker)
  }
}
