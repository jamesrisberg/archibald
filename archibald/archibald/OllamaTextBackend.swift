import Foundation

/// Ollama native `/api/chat` (non-streaming).
struct OllamaTextBackend: AgentTextBackend {
  let baseURLString: String
  let model: String

  func respond(userMessage: String, systemPrompt: String?) async throws -> String {
    let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let base = URL(string: trimmed), let host = base.host, !host.isEmpty else {
      throw AgentTextError.invalidOllamaURL
    }

    let chatURL = base.appendingPathComponent("api").appendingPathComponent("chat")

    var messages: [[String: String]] = []
    if let system = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
      messages.append(["role": "system", "content": system])
    }
    messages.append(["role": "user", "content": userMessage])

    let body: [String: Any] = [
      "model": model,
      "messages": messages,
      "stream": false,
    ]

    var request = URLRequest(url: chatURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AgentTextError.ollamaHTTP(-1, "No HTTP response")
    }
    guard (200...299).contains(http.statusCode) else {
      let text = String(data: data, encoding: .utf8) ?? ""
      throw AgentTextError.ollamaHTTP(http.statusCode, text)
    }

    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = json["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      throw AgentTextError.ollamaDecode
    }

    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
