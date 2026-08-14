@preconcurrency import AVFoundation
import CryptoKit
import Foundation

enum SpeechServiceError: LocalizedError {
  case invalidText
  case invalidResponse(String)
  case noAudio
  case playbackFailed
  case timedOut

  var errorDescription: String? {
    switch self {
    case .invalidText:
      "Edge TTS supports between 1 and 20,000 bytes of text."
    case .invalidResponse(let detail):
      "Edge TTS returned an invalid response: \(detail)"
    case .noAudio:
      "Edge TTS returned no audio. Check your network connection and try again."
    case .playbackFailed:
      "The generated Edge TTS audio could not be played."
    case .timedOut:
      "Edge TTS timed out after 30 seconds. Check your network connection and try again."
    }
  }
}

enum EdgeTTSProtocol {
  static let maximumTextBytes = 20_000
  static let maximumChunkBytes = 4_000
  static let maximumAudioBytes = 25 * 1_024 * 1_024

  private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
  private static let chromiumFullVersion = "143.0.3650.75"

  static func synthesize(
    text: String,
    language: LanguageCode,
    rate: Double,
    volume: Double
  ) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask {
        try await synthesizeWithoutTimeout(
          text: text,
          language: language,
          rate: rate,
          volume: volume
        )
      }
      group.addTask {
        try await Task.sleep(for: .seconds(30))
        throw SpeechServiceError.timedOut
      }
      guard let result = try await group.next() else {
        throw SpeechServiceError.noAudio
      }
      group.cancelAll()
      return result
    }
  }

  private static func synthesizeWithoutTimeout(
    text: String,
    language: LanguageCode,
    rate: Double,
    volume: Double
  ) async throws -> Data {
    let sanitized = sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sanitized.isEmpty, sanitized.utf8.count <= maximumTextBytes else {
      throw SpeechServiceError.invalidText
    }

    let voice = language.edgeVoiceIdentifier
    let ratePercentage = edgeRatePercentage(rate)
    let volumePercentage = min(max(Int((volume * 100).rounded()) - 100, -100), 0)
    var audio = Data()

    for chunk in escapedChunks(sanitized) {
      try Task.checkCancellation()
      let chunkAudio = try await synthesizeChunk(
        escapedText: chunk,
        voice: voice,
        ratePercentage: ratePercentage,
        volumePercentage: volumePercentage
      )
      guard audio.count + chunkAudio.count <= maximumAudioBytes else {
        throw SpeechServiceError.invalidResponse("audio exceeded the safety limit")
      }
      audio.append(chunkAudio)
    }

    guard !audio.isEmpty else { throw SpeechServiceError.noAudio }
    return audio
  }

  static func sanitize(_ text: String) -> String {
    String(
      text.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0...8, 11...12, 14...31:
          " "
        default:
          Character(String(scalar))
        }
      })
  }

  static func escapeXMLCharacter(_ character: Character) -> String {
    switch character {
    case "&": "&amp;"
    case "<": "&lt;"
    case ">": "&gt;"
    case "\"": "&quot;"
    case "'": "&apos;"
    default: String(character)
    }
  }

  static func escapedChunks(_ text: String) -> [String] {
    var chunks: [String] = []
    var current = ""
    var currentBytes = 0

    for character in text {
      let escaped = escapeXMLCharacter(character)
      let escapedBytes = escaped.utf8.count
      if currentBytes + escapedBytes > maximumChunkBytes, !current.isEmpty {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { chunks.append(trimmed) }
        current = ""
        currentBytes = 0
      }
      current += escaped
      currentBytes += escapedBytes
    }

    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { chunks.append(trimmed) }
    return chunks
  }

  static func audioPayload(from message: Data) throws -> Data? {
    guard message.count >= 2 else {
      throw SpeechServiceError.invalidResponse("truncated binary message")
    }
    let headerLength = Int(message[message.startIndex]) << 8
      | Int(message[message.index(after: message.startIndex)])
    let payloadStart = 2 + headerLength
    guard payloadStart <= message.count else {
      throw SpeechServiceError.invalidResponse("invalid binary header length")
    }
    guard let headers = String(data: message.subdata(in: 2..<payloadStart), encoding: .utf8)
    else {
      throw SpeechServiceError.invalidResponse("non-UTF-8 binary headers")
    }
    guard headerValue("Path", in: headers)?.caseInsensitiveCompare("audio") == .orderedSame
    else { return nil }
    if let contentType = headerValue("Content-Type", in: headers),
      contentType.caseInsensitiveCompare("audio/mpeg") != .orderedSame
    {
      throw SpeechServiceError.invalidResponse("unexpected audio content type")
    }
    return message.subdata(in: payloadStart..<message.count)
  }

  private static func synthesizeChunk(
    escapedText: String,
    voice: String,
    ratePercentage: Int,
    volumePercentage: Int
  ) async throws -> Data {
    let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var components = URLComponents()
    components.scheme = "wss"
    components.host = "speech.platform.bing.com"
    components.path = "/consumer/speech/synthesize/readaloud/edge/v1"
    components.queryItems = [
      URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
      URLQueryItem(name: "Sec-MS-GEC", value: securityToken()),
      URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(chromiumFullVersion)"),
      URLQueryItem(name: "ConnectionId", value: connectionID),
    ]
    guard let url = components.url, url.host == "speech.platform.bing.com" else {
      throw SpeechServiceError.invalidResponse("could not construct the fixed service URL")
    }

    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue(
      "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.setValue("muid=\(connectionID.uppercased());", forHTTPHeaderField: "Cookie")
    request.setValue(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
      forHTTPHeaderField: "User-Agent"
    )

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = 15
    sessionConfiguration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: sessionConfiguration)
    let socket = session.webSocketTask(with: request)
    socket.resume()

    return try await withTaskCancellationHandler {
      defer {
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
      }

      let timestamp = edgeTimestamp()
      let speechConfig =
        "X-Timestamp:\(timestamp)\r\n"
        + "Content-Type:application/json; charset=utf-8\r\n"
        + "Path:speech.config\r\n\r\n"
        + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
        + "\r\n"
      try await socket.send(.string(speechConfig))

      let ssml =
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
        + "<voice name='\(voice)'><prosody pitch='+0Hz' rate='\(signed(ratePercentage))%' "
        + "volume='\(signed(volumePercentage))%'>\(escapedText)</prosody></voice></speak>"
      let ssmlMessage =
        "X-RequestId:\(requestID)\r\n"
        + "Content-Type:application/ssml+xml\r\n"
        + "X-Timestamp:\(timestamp)Z\r\n"
        + "Path:ssml\r\n\r\n\(ssml)"
      try await socket.send(.string(ssmlMessage))

      var audio = Data()
      while true {
        try Task.checkCancellation()
        switch try await socket.receive() {
        case .data(let message):
          if let payload = try audioPayload(from: message) {
            guard audio.count + payload.count <= maximumAudioBytes else {
              throw SpeechServiceError.invalidResponse("audio exceeded the safety limit")
            }
            audio.append(payload)
          }
        case .string(let message):
          guard let separator = message.range(of: "\r\n\r\n") else { continue }
          let headers = String(message[..<separator.lowerBound])
          if headerValue("Path", in: headers)?.caseInsensitiveCompare("turn.end") == .orderedSame {
            guard !audio.isEmpty else { throw SpeechServiceError.noAudio }
            return audio
          }
        @unknown default:
          throw SpeechServiceError.invalidResponse("unknown WebSocket message")
        }
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
  }

  private static func headerValue(_ name: String, in headers: String) -> String? {
    for line in headers.components(separatedBy: "\r\n") {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
      else { continue }
      return parts[1].trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  private static func edgeRatePercentage(_ rate: Double) -> Int {
    let normalized = (rate - 0.48) / 0.28
    return min(max(Int((normalized * 50).rounded()), -100), 100)
  }

  private static func signed(_ value: Int) -> String {
    value >= 0 ? "+\(value)" : String(value)
  }

  private static func edgeTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
    return formatter.string(from: Date())
  }

  private static func securityToken(at date: Date = Date()) -> String {
    let unixSeconds = UInt64(max(0, date.timeIntervalSince1970.rounded(.down)))
    let roundedSeconds = unixSeconds - unixSeconds % 300
    let windowsTicks = (roundedSeconds + 11_644_473_600) * 10_000_000
    let digest = SHA256.hash(data: Data("\(windowsTicks)\(trustedClientToken)".utf8))
    return digest.map { String(format: "%02X", $0) }.joined()
  }
}

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate,
  AVAudioPlayerDelegate
{
  @Published private(set) var isSpeaking = false
  @Published private(set) var errorMessage: String?

  private let synthesizer = AVSpeechSynthesizer()
  private var audioPlayer: AVAudioPlayer?
  private var synthesisTask: Task<Void, Never>?
  private var requestID = UUID()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(
    _ text: String,
    language: LanguageCode,
    rate: Double,
    volume: Double,
    provider: TTSProvider = .edge
  ) {
    stop()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    errorMessage = nil
    isSpeaking = true

    if provider == .system {
      let utterance = AVSpeechUtterance(string: trimmed)
      utterance.voice = AVSpeechSynthesisVoice(language: language.localeIdentifier)
      utterance.rate = Float(min(max(rate, 0.1), 0.65))
      utterance.volume = Float(min(max(volume, 0), 1))
      synthesizer.speak(utterance)
      return
    }

    requestID = UUID()
    let activeRequest = requestID
    synthesisTask = Task { [weak self] in
      do {
        let audio = try await EdgeTTSProtocol.synthesize(
          text: trimmed,
          language: language,
          rate: rate,
          volume: volume
        )
        try Task.checkCancellation()
        guard let self, requestID == activeRequest else { return }
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        player.volume = 1
        guard player.prepareToPlay(), player.play() else {
          throw SpeechServiceError.playbackFailed
        }
        audioPlayer = player
        synthesisTask = nil
      } catch is CancellationError {
        // Explicit stops are not user-facing failures.
      } catch {
        guard let self, requestID == activeRequest else { return }
        synthesisTask = nil
        isSpeaking = false
        errorMessage = error.localizedDescription
      }
    }
  }

  func stop() {
    requestID = UUID()
    synthesisTask?.cancel()
    synthesisTask = nil
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    audioPlayer?.stop()
    audioPlayer = nil
    isSpeaking = false
  }

  nonisolated func speechSynthesizer(
    _: AVSpeechSynthesizer,
    didFinish _: AVSpeechUtterance
  ) {
    Task { @MainActor in self.isSpeaking = false }
  }

  nonisolated func speechSynthesizer(
    _: AVSpeechSynthesizer,
    didCancel _: AVSpeechUtterance
  ) {
    Task { @MainActor in self.isSpeaking = false }
  }

  nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
    Task { @MainActor in
      self.audioPlayer = nil
      self.isSpeaking = false
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_: AVAudioPlayer, error: Error?) {
    Task { @MainActor in
      self.audioPlayer = nil
      self.isSpeaking = false
      self.errorMessage = error?.localizedDescription ?? SpeechServiceError.playbackFailed.localizedDescription
    }
  }
}
