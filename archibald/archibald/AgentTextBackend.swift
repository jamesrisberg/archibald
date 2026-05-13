import Foundation

/// Text-only agent used for local / CLI backends (Ollama, Codex, Claude Code, …).
/// Voice (Grok) stays separate; call this with transcript or typed text when you want tool-capable agents.
protocol AgentTextBackend: Sendable {
  func respond(userMessage: String, systemPrompt: String?) async throws -> String
}

enum AgentTextError: LocalizedError {
  case providerDisabled
  case missingExecutable(String)
  case invalidOllamaURL
  case ollamaHTTP(Int, String)
  case ollamaDecode
  case cliNonZero(Int32, String)
  case cliTimeout

  var errorDescription: String? {
    switch self {
    case .providerDisabled:
      return "Text agent is set to Off."
    case .missingExecutable(let message):
      return message
    case .invalidOllamaURL:
      return "Invalid Ollama base URL."
    case .ollamaHTTP(let code, let body):
      return "Ollama HTTP \(code): \(body)"
    case .ollamaDecode:
      return "Could not parse Ollama response."
    case .cliNonZero(let status, let stderr):
      return "Command exited with status \(status): \(stderr)"
    case .cliTimeout:
      return "Command timed out."
    }
  }
}

enum AgentTextBackendFactory {
  /// Returns a backend for the current settings, or `nil` when provider is `.off`.
  static func make(settings: AppSettings) -> (any AgentTextBackend)? {
    switch settings.textAgentProvider {
    case .off:
      return nil
    case .ollama:
      return OllamaTextBackend(
        baseURLString: settings.ollamaBaseURLString,
        model: settings.ollamaModel
      )
    case .claudeCode:
      return CLITextBackend(
        executablePath: settings.claudeCodeExecutablePath,
        arguments: AppSettings.commaSeparatedArguments(settings.claudeCodeArgumentsString),
        workingDirectoryPath: settings.agentWorkingDirectoryPath
      )
    case .codex:
      return CLITextBackend(
        executablePath: settings.codexExecutablePath,
        arguments: AppSettings.commaSeparatedArguments(settings.codexArgumentsString),
        workingDirectoryPath: settings.agentWorkingDirectoryPath
      )
    }
  }
}
