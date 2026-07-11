import Foundation

/// Endpoint builder for xAI's realtime voice agent API.
///
/// Auth is the raw API key as `Authorization: Bearer` — the documented scheme
/// for clients that hold their own key. (The `client_secrets` ephemeral-token
/// flow plus the `xai-client-secret.{token}` WebSocket subprotocol exists for
/// browser clients that must not see the long-lived key; a native app whose
/// user pastes their own key gains nothing from it.)
enum GrokVoiceAPI {
  /// Alias that always tracks xAI's newest voice model, so model deprecations
  /// (e.g. grok-voice-fast-1.0 → grok-voice-think-fast-1.0) don't strand us.
  static let model = "grok-voice-latest"

  /// Realtime session URL. Pass `conversationID` when reconnecting to resume
  /// a prior conversation (requires `resumption.enabled` in the session config;
  /// server keeps history for 30 minutes of inactivity).
  static func sessionURL(conversationID: String? = nil) -> URL {
    var components = URLComponents(string: "wss://api.x.ai/v1/realtime")!
    var items = [URLQueryItem(name: "model", value: model)]
    if let conversationID, !conversationID.isEmpty {
      items.append(URLQueryItem(name: "conversation_id", value: conversationID))
    }
    components.queryItems = items
    return components.url!
  }
}
