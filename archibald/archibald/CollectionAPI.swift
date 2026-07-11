import Foundation

/// Thin async client over xAI's Collections endpoints. Two hosts, two keys:
/// - `management-api.x.ai` with the management key: create collections, attach/detach documents.
/// - `api.x.ai` with the regular API key: file upload.
/// Retrieval happens server-side via the voice session's `file_search` tool;
/// there's also a `POST api.x.ai/v1/documents/search` endpoint if a text-side
/// search path is ever needed.
struct CollectionAPI {
  enum APIError: LocalizedError {
    case missingManagementKey
    case missingAPIKey
    case invalidResponse
    case http(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
      switch self {
      case .missingManagementKey: return "xAI Management API key is empty."
      case .missingAPIKey: return "xAI API key is empty."
      case .invalidResponse: return "Invalid response from xAI."
      case .http(let status, let body):
        return "xAI \(status): \(body.prefix(200))"
      case .decoding(let detail): return "Decode error: \(detail)"
      }
    }
  }

  private static let managementHost = "https://management-api.x.ai"
  private static let apiHost = "https://api.x.ai"

  let apiKey: String
  let managementKey: String
  var session: URLSession = .shared

  // MARK: - Collections

  func createCollection(name: String) async throws -> String {
    guard !managementKey.isEmpty else { throw APIError.missingManagementKey }
    var req = URLRequest(url: URL(string: "\(Self.managementHost)/v1/collections")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["collection_name": name])
    let json = try await sendJSON(req)
    // Docs specify `collection_id`; `id` kept as a defensive fallback.
    guard let id = (json["collection_id"] as? String) ?? (json["id"] as? String) else {
      throw APIError.decoding("create collection: no id field in \(json)")
    }
    return id
  }

  // MARK: - Files

  func uploadFile(localURL: URL) async throws -> String {
    guard !apiKey.isEmpty else { throw APIError.missingAPIKey }
    var req = URLRequest(url: URL(string: "\(Self.apiHost)/v1/files")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let boundary = "----archibald-\(UUID().uuidString)"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let body = try multipartBody(
      boundary: boundary,
      fields: ["purpose": "assistants"],
      fileFieldName: "file",
      fileURL: localURL
    )
    req.httpBody = body
    let json = try await sendJSON(req)
    guard let id = json["id"] as? String else {
      throw APIError.decoding("upload file: no id in \(json)")
    }
    return id
  }

  // MARK: - Attach / detach

  func attach(collectionID: String, fileID: String) async throws {
    guard !managementKey.isEmpty else { throw APIError.missingManagementKey }
    var req = URLRequest(url: URL(string:
      "\(Self.managementHost)/v1/collections/\(collectionID)/documents/\(fileID)")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = "{}".data(using: .utf8)
    _ = try await sendJSON(req)
  }

  func detach(collectionID: String, fileID: String) async throws {
    guard !managementKey.isEmpty else { throw APIError.missingManagementKey }
    var req = URLRequest(url: URL(string:
      "\(Self.managementHost)/v1/collections/\(collectionID)/documents/\(fileID)")!)
    req.httpMethod = "DELETE"
    req.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
    let (_, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
    // 404 = already gone; treat as success since the desired state is "not attached".
    if !(200..<300).contains(http.statusCode) && http.statusCode != 404 {
      throw APIError.http(status: http.statusCode, body: "")
    }
  }

  // MARK: - Helpers

  private func sendJSON(_ req: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      throw APIError.http(status: http.statusCode, body: bodyText)
    }
    if data.isEmpty { return [:] }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw APIError.decoding("not a JSON object")
    }
    return json
  }

  private func multipartBody(
    boundary: String,
    fields: [String: String],
    fileFieldName: String,
    fileURL: URL
  ) throws -> Data {
    var body = Data()
    let dashBoundary = "--\(boundary)\r\n"
    for (name, value) in fields {
      body.append(dashBoundary.data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
      body.append("\(value)\r\n".data(using: .utf8)!)
    }
    body.append(dashBoundary.data(using: .utf8)!)
    let filename = fileURL.lastPathComponent
    body.append(
      "Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n"
        .data(using: .utf8)!)
    body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
    body.append(try Data(contentsOf: fileURL))
    body.append("\r\n".data(using: .utf8)!)
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    return body
  }
}
