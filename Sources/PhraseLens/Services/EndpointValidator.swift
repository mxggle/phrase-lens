import Foundation

enum EndpointValidator {
  static func validate(_ rawValue: String, provider: ProviderKind) throws -> URL {
    guard
      let components = URLComponents(
        string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      ), let url = components.url
    else {
      throw TranslationError.invalidEndpoint("enter a complete URL")
    }
    guard components.user == nil, components.password == nil else {
      throw TranslationError.invalidEndpoint("embedded credentials are not allowed")
    }
    guard components.fragment == nil else {
      throw TranslationError.invalidEndpoint("fragments are not allowed")
    }
    guard let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty
    else {
      throw TranslationError.invalidEndpoint("scheme and host are required")
    }
    if isPrivateAddressLiteral(host), provider != .ollama {
      throw TranslationError.invalidEndpoint(
        "private network address literals are allowed only for Ollama"
      )
    }
    if scheme == "https" {
      return url
    }
    let loopbackHosts = Set(["localhost", "127.0.0.1", "::1"])
    if scheme == "http", provider == .ollama, loopbackHosts.contains(host) {
      return url
    }
    throw TranslationError.invalidEndpoint(
      "HTTPS is required; HTTP is allowed only for loopback Ollama"
    )
  }

  private static func isPrivateAddressLiteral(_ host: String) -> Bool {
    if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc")
      || host.hasPrefix("fd")
    {
      return true
    }
    let octets = host.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
      return false
    }
    return octets[0] == 10
      || octets[0] == 127
      || (octets[0] == 169 && octets[1] == 254)
      || (octets[0] == 172 && (16...31).contains(octets[1]))
      || (octets[0] == 192 && octets[1] == 168)
  }
}
