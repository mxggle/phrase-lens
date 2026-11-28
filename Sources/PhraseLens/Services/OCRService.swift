import AppKit
import Foundation
import ImageIO
import os
@preconcurrency import Vision
@preconcurrency import VisionKit

struct OCRService: Sendable {
  /// A capture smaller than this is a stray click rather than a selection: it
  /// carries no text, so it is treated as a cancelled capture instead of being
  /// reported as a failed recognition.
  private static let smallestUsableCapture = 8

  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.phraselens.app",
    category: "ocr"
  )

  /// The recognizer that read a capture.
  enum Engine: String, Sendable {
    case liveText = "live-text"
    case vision
  }

  struct Recognition: Sendable {
    let text: String
    let engine: Engine
  }

  func captureAndRecognize() async throws -> String {
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nextai-ocr-\(UUID().uuidString)")
      .appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    try await captureInteractively(to: temporaryURL)
    return try await recognize(url: temporaryURL)
  }

  func recognize(url: URL) async throws -> String {
    try await recognition(url: url).text
  }

  /// Reads the text in an image with Live Text, and with Vision when Live
  /// Text is unavailable or finds nothing.
  func recognition(url: URL) async throws -> Recognition {
    // A click that never became a drag still writes a file, so the empty
    // capture is recognised here rather than surfacing as "no text found".
    let size = try Self.pixelSize(at: url)
    guard size.width >= Self.smallestUsableCapture, size.height >= Self.smallestUsableCapture else {
      throw TranslationError.cancelled
    }
    if let text = await Self.liveText(at: url) {
      Self.log.info("recognized engine=live-text size=\(size.width)x\(size.height) characters=\(text.count)")
      return Recognition(text: text, engine: .liveText)
    }
    let text = try await Task.detached(priority: .userInitiated) {
      try Self.visionText(at: url)
    }.value
    Self.log.info("recognized engine=vision size=\(size.width)x\(size.height) characters=\(text.count)")
    guard !text.isEmpty else { throw TranslationError.noTextRecognized }
    return Recognition(text: text, engine: .vision)
  }

  private static func pixelSize(at url: URL) throws -> (width: Int, height: Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      throw TranslationError.provider(L10n.isChinese ? "无法读取图像。" : "Could not read the image.")
    }
    return (width, height)
  }

  /// Live Text, the recognizer behind selecting text in Preview and Photos.
  /// `VNRecognizeTextRequest` only reads horizontal lines: on a manga page it
  /// returned nothing for every vertical speech bubble, at every setting and
  /// at twice the size, while Live Text read each bubble whole — columns in
  /// order, joined into one line — in a few hundredths of a second, and read
  /// horizontal text as well as Vision did. Returns nil when Live Text is
  /// unavailable, fails or finds nothing, so Vision still gets a try.
  @MainActor
  private static func liveText(at url: URL) async -> String? {
    guard ImageAnalyzer.isSupported else {
      log.info("live text unsupported on this Mac")
      return nil
    }
    let configuration = ImageAnalyzer.Configuration([.text])
    do {
      let analysis = try await ImageAnalyzer().analyze(
        imageAt: url, orientation: .up, configuration: configuration)
      let text = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    } catch {
      log.error("live text failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private static func visionText(at url: URL) throws -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw TranslationError.provider(L10n.isChinese ? "无法读取图像。" : "Could not read the image.")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // Vision picks a single recognition model from `recognitionLanguages`, so pinning
    // a Latin language ahead of the CJK ones made it drop Chinese and Japanese text
    // entirely. Let Vision detect the script in the screenshot instead.
    request.automaticallyDetectsLanguage = true
    let handler = VNImageRequestHandler(cgImage: image)
    try handler.perform([request])
    let lines =
      request.results?
      .compactMap { $0.topCandidates(1).first?.string }
      .filter { !$0.isEmpty } ?? []
    return lines.joined(separator: "\n")
  }

  private func captureInteractively(to url: URL) async throws {
    let status = try await runCapture(writingTo: url)
    // `screencapture` hands the interactive selection off to screencaptureui and
    // can return before that helper has finished flushing the PNG, so a single
    // existence check at exit intermittently loses the race and reports a
    // cancellation the user never made. Wait for the file to settle instead.
    guard status == 0, await waitForCapture(at: url) else {
      throw TranslationError.cancelled
    }
  }

  /// Runs the interactive capture and returns its exit status.
  private func runCapture(writingTo url: URL) async throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-x", url.path]
    return try await withCheckedThrowingContinuation { continuation in
      // `terminationHandler` only fires for a process that actually launched, so
      // exactly one of these two paths resumes the continuation.
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  /// Waits for the capture file to exist and stop growing, up to a second.
  /// Returns `false` when nothing was written, which is how a cancelled
  /// selection looks from here.
  private func waitForCapture(at url: URL) async -> Bool {
    var previousSize = -1
    for _ in 0..<20 {
      let size = fileSize(at: url)
      if size > 0, size == previousSize { return true }
      previousSize = size
      try? await Task.sleep(for: .milliseconds(50))
    }
    return fileSize(at: url) > 0
  }

  private func fileSize(at url: URL) -> Int {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? Int
    else {
      return 0
    }
    return size
  }
}
