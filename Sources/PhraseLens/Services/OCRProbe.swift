#if DEBUG
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Runs the real screenshot recognizer on image files from a shell, so text
/// that reads badly — vertical Japanese, say — can be checked without making
/// a capture. Debug builds only.
///
///     PhraseLens --ocr-probe <image>[@x,y,w,h] ...
///
/// `@x,y,w,h` reads a pixel crop of the image (origin at the top left), the
/// way a capture of one speech bubble would arrive.
@MainActor
enum OCRProbe {
  static func run(arguments: [String]) async -> Int32 {
    guard let index = arguments.firstIndex(of: "--ocr-probe"), arguments.count > index + 1 else {
      print("usage: --ocr-probe <image>[@x,y,w,h] ...")
      return 2
    }
    var status: Int32 = 0
    for argument in arguments[(index + 1)...] {
      guard let input = input(for: argument) else {
        print("PROBE \(argument) error=could not read or crop the image")
        status = 1
        continue
      }
      defer { if input.isTemporary { try? FileManager.default.removeItem(at: input.url) } }
      let started = ContinuousClock.now
      do {
        let recognition = try await OCRService().recognition(url: input.url)
        print("PROBE \(argument) engine=\(recognition.engine.rawValue) elapsed=\(started.duration(to: .now))")
        for line in recognition.text.split(separator: "\n", omittingEmptySubsequences: false) {
          print("  | \(line)")
        }
      } catch {
        print("PROBE \(argument) error=\(error.localizedDescription)")
        status = 1
      }
    }
    return status
  }

  private static func input(for argument: String) -> (url: URL, isTemporary: Bool)? {
    guard let separator = argument.lastIndex(of: "@") else {
      return (URL(fileURLWithPath: argument), false)
    }
    let numbers = argument[argument.index(after: separator)...].split(separator: ",").compactMap { Int($0) }
    guard numbers.count == 4 else { return (URL(fileURLWithPath: argument), false) }
    let path = String(argument[..<separator])
    let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let cropped = image.cropping(to: rect)
    else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("phraselens-ocr-probe-\(UUID().uuidString)")
      .appendingPathExtension("png")
    guard
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return (url, true)
  }
}
#endif
