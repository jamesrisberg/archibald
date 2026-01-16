import Foundation

struct GrokSessionConfig: Codable {
  struct AudioFormat: Codable {
    struct Format: Codable {
      let type: String
      let rate: Int?
    }

    let format: Format
  }

  let type: String
  let session: Session

  struct Session: Codable {
    let voice: String
    let instructions: String
    let audio: Audio
  }

  struct Audio: Codable {
    let input: AudioFormat
    let output: AudioFormat
  }
}

final class GrokVoiceClient {
  private let tokenEndpoint: URL
  let sessionEndpoint: URL

  init(tokenEndpoint: URL, sessionEndpoint: URL = URL(string: "wss://api.x.ai/v1/realtime")!) {
    self.tokenEndpoint = tokenEndpoint
    self.sessionEndpoint = sessionEndpoint
  }

  func fetchEphemeralToken(apiKey: String) async throws -> String {
    guard let url = URL(string: "https://api.x.ai/v1/realtime/client_secrets") else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "expires_after": ["seconds": 300]
    ])

    logHttpRequest("POST", url: url, body: request.httpBody)
    let (data, response) = try await URLSession.shared.data(for: request)
    logHttpResponse(response, data: data)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      let body = String(decoding: data, as: UTF8.self)
      throw NSError(
        domain: "GrokVoiceClient",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "Token request failed (\(http.statusCode)): \(body)"]
      )
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let token = json?["client_secret"] as? String {
      return token
    }
    if let secret = json?["client_secret"] as? [String: Any],
      let token = secret["value"] as? String
    {
      return token
    }
    if let token = json?["value"] as? String {
      return token
    }
    let body = String(decoding: data, as: UTF8.self)
    throw NSError(
      domain: "GrokVoiceClient",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: "Unexpected token response: \(body)"]
    )
  }

  func fetchEphemeralToken() async throws -> String {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    logHttpRequest("POST", url: tokenEndpoint, body: request.httpBody)
    let (data, response) = try await URLSession.shared.data(for: request)
    logHttpResponse(response, data: data)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let token = json?["client_secret"] as? String {
      return token
    }
    throw URLError(.badServerResponse)
  }

  private func logHttpRequest(_ method: String, url: URL, body: Data?) {
    NSLog("[Grok HTTP OUT] \(method) \(url.absoluteString)")
    if let body, let bodyString = String(data: body, encoding: .utf8) {
      NSLog("[Grok HTTP OUT] Body \(bodyString)")
    }
  }

  private func logHttpResponse(_ response: URLResponse, data: Data) {
    if let http = response as? HTTPURLResponse {
      NSLog("[Grok HTTP IN] Status \(http.statusCode)")
    } else {
      NSLog("[Grok HTTP IN] Response \(response)")
    }
    if let body = String(data: data, encoding: .utf8) {
      let maxLength = 1200
      let truncated = body.count > maxLength ? String(body.prefix(maxLength)) + "…<truncated>" : body
      NSLog("[Grok HTTP IN] Body \(truncated)")
    }
  }
}
