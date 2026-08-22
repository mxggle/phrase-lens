import AppKit
import Foundation
import ImageIO
@preconcurrency import Vision

struct OCRService: Sendable {
  /// A capture smaller than this is a stray click rather than a selection: it
  /// carries no text, so it is treated as a cancelled capture instead of being
  /// reported as a failed recognition.
  private static let smallestUsableCapture = 8

  func captureAndRecognize() async throws -> String {
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nextai-ocr-\(UUID().uuidString)")
      .appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    try await captureInteractively(to: temporaryURL)
    return try await recognize(url: temporaryURL)
  }

  func recognize(url: URL) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        throw TranslationError.provider("Could not read the image.")
      }
      // A click that never became a drag still writes a file, so the empty
      // capture is recognised here rather than surfacing as "no text found".
      guard image.width >= Self.smallestUsableCapture,
        image.height >= Self.smallestUsableCapture
      else {
        throw TranslationError.cancelled
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
      let result = lines.joined(separator: "\n")
      guard !result.isEmpty else { throw TranslationError.noTextRecognized }
      return result
    }.value
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
