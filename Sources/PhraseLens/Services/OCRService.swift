import AppKit
import Foundation
import ImageIO
@preconcurrency import Vision

struct OCRService: Sendable {
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
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = ["en-US", "ja-JP", "zh-Hans", "zh-Hant"]
      let handler = VNImageRequestHandler(cgImage: image)
      try handler.perform([request])
      let lines =
        request.results?
        .compactMap { $0.topCandidates(1).first?.string }
        .filter { !$0.isEmpty } ?? []
      let result = lines.joined(separator: "\n")
      guard !result.isEmpty else {
        throw TranslationError.provider("No text was found in the screenshot.")
      }
      return result
    }.value
  }

  private func captureInteractively(to url: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-i", "-x", url.path]
      process.terminationHandler = { process in
        if process.terminationStatus == 0,
          FileManager.default.fileExists(atPath: url.path)
        {
          continuation.resume()
        } else {
          continuation.resume(throwing: TranslationError.cancelled)
        }
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
