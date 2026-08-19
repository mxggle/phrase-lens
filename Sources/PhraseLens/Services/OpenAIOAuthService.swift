import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Service managing OAuth 2.0 Authorization Code Flow with PKCE for OpenAI / ChatGPT Codex subscriptions.
actor OpenAIOAuthService {
  static let shared = OpenAIOAuthService()

  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let redirectURI = "http://localhost:1455/auth/callback"
  static let authorizeURL = "https://auth.openai.com/oauth/authorize"
  static let tokenURL = "https://auth.openai.com/oauth/token"
  static let loopbackPort: UInt16 = 1455

  private var activeListener: NWListener?
  private var activeContinuation: CheckedContinuation<String, Error>?

  // MARK: - OAuth Flow Initiation

  /// Starts the browser-based OAuth 2.0 PKCE login flow.
  func authenticate(proxy: ProxySettings) async throws -> OAuthCredentials {
    cancelPending()

    let verifier = generateCodeVerifier()
    let challenge = generateCodeChallenge(from: verifier)
    let state = generateState()

    let authCode = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      self.activeContinuation = continuation

      do {
        try startLoopbackListener(expectedState: state)
      } catch {
        continuation.resume(throwing: error)
        self.activeContinuation = nil
        return
      }

      // Construct authorization URL
      var components = URLComponents(string: Self.authorizeURL)!
      components.queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: Self.clientID),
        URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        URLQueryItem(name: "scope", value: "openid profile email offline_access"),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "id_token_add_organizations", value: "true"),
        URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      ]

      guard let url = components.url else {
        continuation.resume(throwing: OAuthError.invalidURL)
        self.activeContinuation = nil
        return
      }

      DispatchQueue.main.async {
        NSWorkspace.shared.open(url)
      }
    }

    return try await exchangeCodeForToken(code: authCode, verifier: verifier, proxy: proxy)
  }

  /// Cancels any ongoing OAuth authorization attempt and stops the local listener.
  func cancelPending() {
    stopListener()
    if let continuation = activeContinuation {
      activeContinuation = nil
      continuation.resume(throwing: OAuthError.cancelled)
    }
  }

  private func handleAuthCallbackResult(_ result: Result<String, Error>) {
    guard let continuation = activeContinuation else { return }
    activeContinuation = nil
    stopListener()
    continuation.resume(with: result)
  }

  // MARK: - Token Exchange & Refresh

  /// Exchanges an authorization code and PKCE verifier for OAuth tokens.
  func exchangeCodeForToken(
    code: String,
    verifier: String,
    proxy: ProxySettings
  ) async throws -> OAuthCredentials {
    guard let url = URL(string: Self.tokenURL) else {
      throw OAuthError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let bodyParameters = [
      "grant_type": "authorization_code",
      "client_id": Self.clientID,
      "code": code,
      "code_verifier": verifier,
      "redirect_uri": Self.redirectURI,
    ]

    request.httpBody = formURLEncode(bodyParameters).data(using: .utf8)

    let session = makeSession(proxy: proxy)
    let (data, response) = try await session.data(for: request)

    guard let http = response as? HTTPURLResponse else {
      throw OAuthError.invalidResponse
    }

    guard (200..<300).contains(http.statusCode) else {
      let bodyString = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
      throw OAuthError.exchangeFailed(bodyString)
    }

    return try parseTokenResponse(data)
  }

  /// Refreshes an existing OAuth credential using its refresh token.
  func refreshCredentials(
    _ current: OAuthCredentials,
    proxy: ProxySettings
  ) async throws -> OAuthCredentials {
    guard !current.refreshToken.isEmpty else {
      throw OAuthError.missingRefreshToken
    }
    guard let url = URL(string: Self.tokenURL) else {
      throw OAuthError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let bodyParameters = [
      "grant_type": "refresh_token",
      "client_id": Self.clientID,
      "refresh_token": current.refreshToken,
    ]

    request.httpBody = formURLEncode(bodyParameters).data(using: .utf8)

    let session = makeSession(proxy: proxy)
    let (data, response) = try await session.data(for: request)

    guard let http = response as? HTTPURLResponse else {
      throw OAuthError.invalidResponse
    }

    guard (200..<300).contains(http.statusCode) else {
      let bodyString = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
      throw OAuthError.refreshFailed(bodyString)
    }

    var updated = try parseTokenResponse(data)
    // If the refresh response didn't include a new refresh token, preserve the existing one.
    if updated.refreshToken.isEmpty {
      updated.refreshToken = current.refreshToken
    }
    if updated.email == nil {
      updated.email = current.email
    }
    if updated.accountId == nil {
      updated.accountId = current.accountId
    }
    return updated
  }

  // MARK: - PKCE Helpers

  nonisolated func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URLEncode(Data(bytes))
  }

  nonisolated func generateCodeChallenge(from verifier: String) -> String {
    let hashed = SHA256.hash(data: Data(verifier.utf8))
    return base64URLEncode(Data(hashed))
  }

  private func generateState() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  private nonisolated func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
  }

  private func formURLEncode(_ parameters: [String: String]) -> String {
    parameters.compactMap { key, value in
      guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
      else { return nil }
      return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
  }

  // MARK: - Parsing Token Response

  private func parseTokenResponse(_ data: Data) throws -> OAuthCredentials {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = json["access_token"] as? String
    else {
      throw OAuthError.invalidResponse
    }

    let refreshToken = json["refresh_token"] as? String ?? ""
    let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
    let tokenType = json["token_type"] as? String ?? "Bearer"
    let expiresAt = Date().addingTimeInterval(expiresIn)

    var email: String?
    var accountId: String?
    if let idToken = json["id_token"] as? String,
      let payload = jwtPayload(idToken)
    {
      email = payload["email"] as? String
        ?? (payload["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
      accountId = chatGPTAccountId(from: payload)
    }
    // The access token carries the same auth claim, so it works as a fallback
    // when the id_token is absent or shaped differently.
    if accountId == nil, let payload = jwtPayload(accessToken) {
      accountId = chatGPTAccountId(from: payload)
    }

    return OAuthCredentials(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      tokenType: tokenType,
      email: email,
      accountId: accountId
    )
  }

  /// The Codex backend routes multi-organization accounts by this header, and
  /// OpenAI embeds it in the tokens it issues.
  private func chatGPTAccountId(from payload: [String: Any]) -> String? {
    (payload["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
  }

  private func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var base64 = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
      base64.append("=")
    }
    guard let data = Data(base64Encoded: base64) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  // MARK: - Loopback Listener (port 1455)

  private func startLoopbackListener(expectedState: String) throws {
    stopListener()

    guard let port = NWEndpoint.Port(rawValue: Self.loopbackPort) else {
      throw OAuthError.portUnavailable
    }

    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let listener = try NWListener(using: params, on: port)
    self.activeListener = listener

    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue: .global())
      Task { [weak self] in
        await self?.handleIncomingConnection(
          connection,
          expectedState: expectedState
        )
      }
    }

    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        break
      case .failed(let error):
        Task { [weak self] in
          await self?.handleAuthCallbackResult(.failure(OAuthError.listenerFailed(error.localizedDescription)))
        }
      case .cancelled:
        break
      default:
        break
      }
    }

    listener.start(queue: .global())
  }

  private func handleIncomingConnection(
    _ connection: NWConnection,
    expectedState: String
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
      if let error {
        Task { [weak self] in
          await self?.handleAuthCallbackResult(.failure(error))
        }
        connection.cancel()
        return
      }

      guard let data, let requestString = String(data: data, encoding: .utf8) else {
        connection.cancel()
        return
      }

      // Parse GET /auth/callback?code=...&state=...
      guard let firstLine = requestString.components(separatedBy: "\r\n").first,
        firstLine.hasPrefix("GET ")
      else {
        connection.cancel()
        return
      }

      let parts = firstLine.split(separator: " ")
      guard parts.count >= 2 else {
        connection.cancel()
        return
      }

      let pathWithQuery = String(parts[1])
      guard let urlComponents = URLComponents(string: "http://localhost:1455\(pathWithQuery)") else {
        connection.cancel()
        return
      }

      let queryItems = urlComponents.queryItems ?? []
      let code = queryItems.first(where: { $0.name == "code" })?.value
      let state = queryItems.first(where: { $0.name == "state" })?.value
      let errorParam = queryItems.first(where: { $0.name == "error" })?.value
      let errorDescription = queryItems.first(where: { $0.name == "error_description" })?.value

      let htmlResponse: String
      if let errorParam {
        htmlResponse = Self.callbackHTML(
          status: .error,
          title: "Authentication Failed",
          message: "Unable to complete authentication with your ChatGPT account. Please close this window and try again.",
          detailMessage: errorDescription ?? errorParam,
          buttonTitle: "Close Window",
          showCountdown: false
        )
      } else if code != nil, state == expectedState {
        htmlResponse = Self.callbackHTML(
          status: .success,
          title: "Authentication Successful",
          message: "You have successfully signed in with your ChatGPT account for PhraseLens.<br>You can safely return to the app.",
          detailMessage: nil,
          buttonTitle: "Return to PhraseLens",
          showCountdown: true
        )
      } else {
        htmlResponse = Self.callbackHTML(
          status: .warning,
          title: "Invalid Authorization State",
          message: "The authorization callback security state did not match. Please return to PhraseLens and try signing in again.",
          detailMessage: "OAuth state parameter mismatch",
          buttonTitle: "Close Window",
          showCountdown: false
        )
      }

      let httpResponse = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(htmlResponse.utf8.count)\r
        Connection: close\r
        \r
        \(htmlResponse)
        """

      connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
        connection.cancel()
      })

      Task { [weak self] in
        if let errorParam {
          await self?.handleAuthCallbackResult(.failure(OAuthError.remoteError(errorDescription ?? errorParam)))
        } else if let code, state == expectedState {
          await self?.handleAuthCallbackResult(.success(code))
        } else {
          await self?.handleAuthCallbackResult(.failure(OAuthError.invalidState))
        }
      }
    }
  }

  private func stopListener() {
    activeListener?.cancel()
    activeListener = nil
  }

  private enum CallbackStatus {
    case success
    case error
    case warning

    var tagText: String {
      switch self {
      case .success: "PhraseLens Authorization"
      case .error: "Authorization Failed"
      case .warning: "Security Verification"
      }
    }

    var statusRowLabel: String {
      switch self {
      case .success: "Active & Connected"
      case .error: "Authorization Error"
      case .warning: "Verification Mismatch"
      }
    }

    var glowColor: String {
      switch self {
      case .success: "rgba(16, 185, 129, 0.16)"
      case .error: "rgba(239, 68, 68, 0.16)"
      case .warning: "rgba(245, 158, 11, 0.16)"
      }
    }

    var lightGlowColor: String {
      switch self {
      case .success: "rgba(22, 163, 74, 0.12)"
      case .error: "rgba(220, 38, 38, 0.10)"
      case .warning: "rgba(217, 119, 6, 0.10)"
      }
    }

    var statusColor: String {
      switch self {
      case .success: "#10b981"
      case .error: "#ef4444"
      case .warning: "#f59e0b"
      }
    }

    var statusGlow: String {
      switch self {
      case .success: "rgba(16, 185, 129, 0.22)"
      case .error: "rgba(239, 68, 68, 0.22)"
      case .warning: "rgba(245, 158, 11, 0.22)"
      }
    }

    var statusSubtle: String {
      switch self {
      case .success: "rgba(16, 185, 129, 0.12)"
      case .error: "rgba(239, 68, 68, 0.12)"
      case .warning: "rgba(245, 158, 11, 0.12)"
      }
    }

    var iconSVG: String {
      switch self {
      case .success:
        return """
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round">
            <polyline class="checkmark-path" points="20 6 9 17 4 12"></polyline>
          </svg>
          """
      case .error:
        return """
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <line x1="18" y1="6" x2="6" y2="18"></line>
            <line x1="6" y1="6" x2="18" y2="18"></line>
          </svg>
          """
      case .warning:
        return """
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path>
            <line x1="12" y1="9" x2="12" y2="13"></line>
            <line x1="12" y1="17" x2="12.01" y2="17"></line>
          </svg>
          """
      }
    }
  }

  private static let appLogoBase64 = "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"

  private static func callbackHTML(
    status: CallbackStatus,
    title: String,
    message: String,
    detailMessage: String? = nil,
    buttonTitle: String = "Return to PhraseLens",
    showCountdown: Bool = true
  ) -> String {
    let detailsRowHTML: String
    if let detailMessage, !detailMessage.isEmpty {
      detailsRowHTML = """
        <div class="meta-row">
          <span class="meta-label">Details</span>
          <span class="meta-value" style="font-family: monospace; font-size: 0.78rem; word-break: break-all;">\(detailMessage)</span>
        </div>
        """
    } else {
      detailsRowHTML = ""
    }

    let countdownHTML = showCountdown ? """
      <div id="countdownNote" class="countdown-text">
        Auto-closing tab in <span id="timer">4</span>s…
      </div>
      """ : ""

    let countdownScript = showCountdown ? """
      let remaining = 4;
      let isCancelled = false;
      const timerElem = document.getElementById('timer');
      const noteElem = document.getElementById('countdownNote');

      document.addEventListener('mousemove', pauseCountdown, { once: true });
      document.addEventListener('keydown', pauseCountdown, { once: true });

      function pauseCountdown() {
        if (isCancelled) return;
        isCancelled = true;
        if (noteElem) {
          noteElem.style.opacity = '0';
        }
      }

      const interval = setInterval(() => {
        if (isCancelled) {
          clearInterval(interval);
          return;
        }
        remaining -= 1;
        if (timerElem) timerElem.textContent = remaining;
        if (remaining <= 0) {
          clearInterval(interval);
          closeWindow();
        }
      }, 1000);
      """ : ""

    return """
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>PhraseLens — \(title)</title>
        <style>
          :root {
            --bg: #09090b;
            --card-bg: rgba(19, 19, 22, 0.88);
            --card-border: rgba(255, 255, 255, 0.08);
            --card-highlight: rgba(255, 255, 255, 0.12);
            --surface-subtle: rgba(255, 255, 255, 0.04);
            --surface-subtle-border: rgba(255, 255, 255, 0.06);
            --text-main: #fafafa;
            --text-secondary: #d4d4d8;
            --text-muted: #9b9ba3;
            --text-faint: #6b6b73;
            --accent: #38bdf8;
            --status: \(status.statusColor);
            --status-glow: \(status.statusGlow);
            --status-subtle: \(status.statusSubtle);
            --btn-bg: #fafafa;
            --btn-text: #09090b;
            --btn-hover: #e4e4e7;
            --kbd-bg: rgba(255, 255, 255, 0.08);
            --kbd-border: rgba(255, 255, 255, 0.12);
            --shadow-ambient: rgba(0, 0, 0, 0.6);
            --glow-color: \(status.glowColor);
          }

          @media (prefers-color-scheme: light) {
            :root {
              --bg: #f7f7f8;
              --card-bg: rgba(255, 255, 255, 0.94);
              --card-border: rgba(0, 0, 0, 0.08);
              --card-highlight: rgba(255, 255, 255, 0.8);
              --surface-subtle: rgba(0, 0, 0, 0.03);
              --surface-subtle-border: rgba(0, 0, 0, 0.06);
              --text-main: #09090b;
              --text-secondary: #3f3f46;
              --text-muted: #71717a;
              --text-faint: #85858e;
              --accent: #0284c7;
              --status: \(status.statusColor);
              --status-glow: \(status.statusGlow);
              --status-subtle: \(status.statusSubtle);
              --btn-bg: #18181b;
              --btn-text: #fafafa;
              --btn-hover: #27272a;
              --kbd-bg: rgba(0, 0, 0, 0.05);
              --kbd-border: rgba(0, 0, 0, 0.12);
              --shadow-ambient: rgba(9, 9, 11, 0.12);
              --glow-color: \(status.lightGlowColor);
            }
          }

          * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
          }

          html, body {
            width: 100%;
            height: 100%;
            min-height: 100vh;
          }

          body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg);
            color: var(--text-main);
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 1.5rem;
            position: relative;
            overflow-x: hidden;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
          }

          .bg-mesh {
            position: fixed;
            inset: 0;
            pointer-events: none;
            background:
              radial-gradient(circle 450px at 50% 32%, var(--glow-color), transparent 70%),
              radial-gradient(circle 600px at 85% 85%, rgba(56, 189, 248, 0.06), transparent 70%),
              radial-gradient(circle 500px at 15% 75%, rgba(168, 85, 247, 0.04), transparent 70%);
            z-index: 0;
          }

          .bg-grid {
            position: fixed;
            inset: 0;
            pointer-events: none;
            background-image:
              linear-gradient(to right, var(--card-border) 1px, transparent 1px),
              linear-gradient(to bottom, var(--card-border) 1px, transparent 1px);
            background-size: 32px 32px;
            opacity: 0.3;
            mask-image: radial-gradient(circle at center, black 40%, transparent 80%);
            -webkit-mask-image: radial-gradient(circle at center, black 40%, transparent 80%);
            z-index: 0;
          }

          .container {
            position: relative;
            z-index: 10;
            width: 100%;
            max-width: 440px;
            margin: auto;
          }

          .card {
            background: var(--card-bg);
            backdrop-filter: blur(28px);
            -webkit-backdrop-filter: blur(28px);
            border: 1px solid var(--card-border);
            border-radius: 20px;
            padding: 2.25rem 2rem 2rem;
            text-align: center;
            box-shadow:
              0 0 0 1px var(--card-highlight) inset,
              0 24px 48px -12px var(--shadow-ambient),
              0 2px 6px rgba(0, 0, 0, 0.06);
            animation: cardEntrance 0.45s cubic-bezier(0.16, 1, 0.3, 1) forwards;
          }

          @keyframes cardEntrance {
            from {
              opacity: 0;
              transform: translateY(14px) scale(0.985);
            }
            to {
              opacity: 1;
              transform: translateY(0) scale(1);
            }
          }

          .integration-header {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 12px;
            margin-bottom: 1.5rem;
          }

          .app-icon {
            width: 46px;
            height: 46px;
            border-radius: 12px;
            background: linear-gradient(135deg, #18181b 0%, #09090b 100%);
            border: 1px solid var(--card-border);
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
            overflow: hidden;
          }

          .link-bridge {
            display: flex;
            align-items: center;
            justify-content: center;
            position: relative;
            width: 32px;
          }

          .link-line {
            width: 100%;
            height: 2px;
            background: linear-gradient(90deg, var(--card-border) 0%, var(--status) 50%, var(--card-border) 100%);
            border-radius: 1px;
          }

          .link-dot {
            position: absolute;
            width: 6px;
            height: 6px;
            border-radius: 50%;
            background: var(--status);
            box-shadow: 0 0 8px var(--status);
          }

          .openai-icon {
            width: 46px;
            height: 46px;
            border-radius: 12px;
            background: linear-gradient(135deg, #10a37f 0%, #0d8c6d 100%);
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 4px 14px rgba(16, 163, 127, 0.35);
            color: #ffffff;
          }

          .openai-icon svg {
            width: 25px;
            height: 25px;
            fill: currentColor;
          }

          .status-badge-container {
            margin-bottom: 1.25rem;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            position: relative;
          }

          .status-circle-halo {
            position: absolute;
            width: 56px;
            height: 56px;
            border-radius: 50%;
            background: var(--status-glow);
            animation: haloPulse 2.4s infinite ease-in-out;
          }

          @keyframes haloPulse {
            0%, 100% { transform: scale(1); opacity: 0.6; }
            50% { transform: scale(1.2); opacity: 0.2; }
          }

          .status-circle {
            width: 46px;
            height: 46px;
            border-radius: 50%;
            background: var(--status-subtle);
            border: 1.5px solid var(--status);
            display: flex;
            align-items: center;
            justify-content: center;
            position: relative;
            z-index: 1;
            color: var(--status);
          }

          .status-circle svg {
            width: 22px;
            height: 22px;
          }

          .checkmark-path {
            stroke-dasharray: 24;
            stroke-dashoffset: 24;
            animation: drawCheckmark 0.55s 0.15s cubic-bezier(0.65, 0, 0.45, 1) forwards;
          }

          @keyframes drawCheckmark {
            to {
              stroke-dashoffset: 0;
            }
          }

          .brand-tag {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 4px 12px;
            border-radius: 999px;
            background: var(--surface-subtle);
            border: 1px solid var(--surface-subtle-border);
            font-size: 0.74rem;
            font-weight: 600;
            letter-spacing: 0.05em;
            text-transform: uppercase;
            color: var(--text-muted);
            margin-bottom: 0.75rem;
          }

          .brand-tag-dot {
            width: 6px;
            height: 6px;
            border-radius: 50%;
            background: var(--status);
            box-shadow: 0 0 6px var(--status);
          }

          h1 {
            font-size: 1.4rem;
            font-weight: 650;
            letter-spacing: -0.02em;
            line-height: 1.3;
            margin-bottom: 0.6rem;
            color: var(--text-main);
          }

          .description {
            color: var(--text-muted);
            font-size: 0.92rem;
            line-height: 1.55;
            margin-bottom: 1.35rem;
          }

          .meta-box {
            background: var(--surface-subtle);
            border: 1px solid var(--surface-subtle-border);
            border-radius: 12px;
            padding: 0.85rem 1rem;
            margin-bottom: 1.5rem;
            text-align: left;
            display: flex;
            flex-direction: column;
            gap: 8px;
          }

          .meta-row {
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 0.82rem;
          }

          .meta-label {
            color: var(--text-faint);
          }

          .meta-value {
            color: var(--text-secondary);
            font-weight: 500;
            display: flex;
            align-items: center;
            gap: 6px;
          }

          .meta-value-dot {
            width: 6px;
            height: 6px;
            border-radius: 50%;
            background: var(--status);
          }

          .actions {
            display: flex;
            flex-direction: column;
            gap: 10px;
          }

          .btn-primary {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            width: 100%;
            height: 42px;
            border-radius: 10px;
            background: var(--btn-bg);
            color: var(--btn-text);
            font-size: 0.92rem;
            font-weight: 600;
            text-decoration: none;
            border: none;
            cursor: pointer;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12);
            transition: all 0.16s ease;
          }

          .btn-primary:hover {
            background: var(--btn-hover);
            transform: translateY(-1px);
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.18);
          }

          .btn-primary:active {
            transform: translateY(0);
          }

          .shortcut-hint {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 5px;
            font-size: 0.76rem;
            color: var(--text-faint);
            margin-top: 0.25rem;
          }

          kbd {
            display: inline-block;
            padding: 1px 5px;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", monospace;
            font-size: 0.72rem;
            font-weight: 600;
            line-height: 1.3;
            color: var(--text-muted);
            background: var(--kbd-bg);
            border: 1px solid var(--kbd-border);
            border-radius: 4px;
          }

          .countdown-text {
            font-size: 0.76rem;
            color: var(--text-faint);
            margin-top: 0.85rem;
            transition: opacity 0.2s;
          }

          @media (prefers-reduced-motion: reduce) {
            .card, .status-circle-halo, .link-dot, .checkmark-path {
              animation: none !important;
            }
            .checkmark-path {
              stroke-dashoffset: 0 !important;
            }
          }
        </style>
      </head>
      <body>
        <div class="bg-mesh"></div>
        <div class="bg-grid"></div>

        <div class="container">
          <div class="card">
            <!-- Brand Lockup -->
            <div class="integration-header">
              <div class="app-icon" title="PhraseLens">
                <img src="data:image/png;base64,\(Self.appLogoBase64)" alt="PhraseLens" style="width: 100%; height: 100%; object-fit: cover; display: block;">
              </div>

              <div class="link-bridge">
                <div class="link-line"></div>
                <div class="link-dot"></div>
              </div>

              <div class="openai-icon" title="OpenAI / ChatGPT">
                <svg viewBox="0 0 24 24">
                  <path d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1683a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4947zm-9.66-4.1354a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1401-1.6564zm-1.8025-10.742a4.4755 4.4755 0 0 1 2.3418-1.9729v5.6725a.7617.7617 0 0 0 .3879.6765l5.8144 3.3543-2.02 1.1683a.0757.0757 0 0 1-.071 0l-4.8303-2.7866a4.504 4.504 0 0 1-1.6228-6.1122zm15.7481 4.5242l-5.8428-3.3685 2.02-1.1683a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.402-.6815zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L7.409 9.6083V7.276a.0852.0852 0 0 1 .0332-.0616l4.981-2.8764a4.4992 4.4992 0 0 1 6.6747 4.6713zm-9.3364 4.3397l-2.7345-1.5767 2.7345-1.5767 2.7345 1.5767z"/>
                </svg>
              </div>
            </div>

            <!-- Status Indicator -->
            <div class="status-badge-container">
              <div class="status-circle-halo"></div>
              <div class="status-circle">
                \(status.iconSVG)
              </div>
            </div>

            <!-- Tag -->
            <div>
              <div class="brand-tag">
                <span class="brand-tag-dot"></span>
                <span>\(status.tagText)</span>
              </div>
            </div>

            <!-- Title & Message -->
            <h1>\(title)</h1>
            <p class="description">\(message)</p>

            <!-- Meta Box -->
            <div class="meta-box">
              <div class="meta-row">
                <span class="meta-label">Provider</span>
                <span class="meta-value">OpenAI / ChatGPT</span>
              </div>
              <div class="meta-row">
                <span class="meta-label">Status</span>
                <span class="meta-value"><span class="meta-value-dot"></span> \(status.statusRowLabel)</span>
              </div>
              \(detailsRowHTML)
            </div>

            <!-- Action Buttons -->
            <div class="actions">
              <button id="closeBtn" class="btn-primary" onclick="closeWindow()">
                <span>\(buttonTitle)</span>
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                  <line x1="5" y1="12" x2="19" y2="12"></line>
                  <polyline points="12 5 19 12 12 19"></polyline>
                </svg>
              </button>

              <div class="shortcut-hint">
                <span>Or press</span>
                <kbd>⌘</kbd>
                <kbd>W</kbd>
                <span>to close this tab</span>
              </div>
            </div>

            \(countdownHTML)
          </div>
        </div>

        <script>
          \(countdownScript)

          function closeWindow() {
            window.close();
            const btn = document.getElementById('closeBtn');
            if (btn) {
              btn.innerHTML = '<span>Switch back to PhraseLens</span>';
            }
          }
        </script>
      </body>
      </html>
      """
  }

  private func makeSession(proxy: ProxySettings) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    if proxy.enabled, !proxy.host.isEmpty {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: proxy.scheme == "http",
        kCFNetworkProxiesHTTPProxy as String: proxy.host,
        kCFNetworkProxiesHTTPPort as String: proxy.port,
        kCFNetworkProxiesHTTPSEnable as String: proxy.scheme == "https",
        kCFNetworkProxiesHTTPSProxy as String: proxy.host,
        kCFNetworkProxiesHTTPSPort as String: proxy.port,
      ]
    }
    return URLSession(configuration: configuration)
  }
}

enum OAuthError: LocalizedError, Equatable {
  case invalidURL
  case invalidResponse
  case invalidState
  case portUnavailable
  case listenerFailed(String)
  case exchangeFailed(String)
  case refreshFailed(String)
  case remoteError(String)
  case missingRefreshToken
  case cancelled

  var errorDescription: String? {
    switch self {
    case .invalidURL: "Invalid OAuth URL."
    case .invalidResponse: "The OAuth authorization server returned an invalid response."
    case .invalidState: "OAuth security state mismatch. Please try signing in again."
    case .portUnavailable: "Local callback port (1455) is already in use by another application."
    case .listenerFailed(let reason): "Failed to start OAuth callback listener: \(reason)"
    case .exchangeFailed(let reason): "Failed to exchange OAuth token: \(reason)"
    case .refreshFailed(let reason): "Failed to refresh ChatGPT token: \(reason)"
    case .remoteError(let reason): "OAuth authorization failed: \(reason)"
    case .missingRefreshToken: "No refresh token available. Please sign in again."
    case .cancelled: "OAuth authentication was cancelled."
    }
  }
}
