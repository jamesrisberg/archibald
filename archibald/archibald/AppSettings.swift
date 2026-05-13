import Combine
import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
  enum OrbCorner: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .topLeft: return "Top Left"
      case .topRight: return "Top Right"
      case .bottomLeft: return "Bottom Left"
      case .bottomRight: return "Bottom Right"
      }
    }
  }

  enum VoiceOption: String, CaseIterable, Identifiable {
    case ara = "Ara"
    case rex = "Rex"
    case sal = "Sal"
    case eve = "Eve"
    case leo = "Leo"

    var id: String { rawValue }
  }

  enum HotKeyOption: String, CaseIterable, Identifiable {
    case optionBackslash
    case shiftBackslash
    case optionSpace
    case controlSpace
    case commandShiftSpace

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .optionBackslash: return "Option + \\"
      case .shiftBackslash: return "Shift + \\"
      case .optionSpace: return "Option + Space"
      case .controlSpace: return "Control + Space"
      case .commandShiftSpace: return "Command + Shift + Space"
      }
    }
  }

  /// Local text agent (Ollama HTTP or a CLI). Separate from Grok voice.
  enum TextAgentProvider: String, CaseIterable, Identifiable {
    case off
    case ollama
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .off: return "Off"
      case .ollama: return "Ollama"
      case .claudeCode: return "Claude Code (CLI)"
      case .codex: return "Codex (CLI)"
      }
    }
  }

  private enum Keys {
    static let corner = "orb.corner"
    static let orbSize = "orb.size"
    static let isOrbVisible = "orb.visible"
    static let isListening = "orb.listening"
    static let voice = "voice.selected"
    static let systemPrompt = "voice.systemPrompt"
    static let apiKey = "voice.apiKey"
    static let debugLogging = "debug.logging"
    static let primaryHotKey = "hotkey.primary"
    static let textAgentProvider = "textAgent.provider"
    static let ollamaBaseURL = "textAgent.ollamaBaseURL"
    static let ollamaModel = "textAgent.ollamaModel"
    static let claudeCodeExecutablePath = "textAgent.claudeCodeExecutablePath"
    static let codexExecutablePath = "textAgent.codexExecutablePath"
    static let claudeCodeArgumentsString = "textAgent.claudeCodeArgumentsString"
    static let codexArgumentsString = "textAgent.codexArgumentsString"
    static let agentWorkingDirectoryPath = "textAgent.workingDirectoryPath"
    static let fileCollectionsEnabled = "collections.enabled"
    static let xaiManagementAPIKey = "collections.managementAPIKey"
    static let collectionFolderPath = "collections.folderPath"
    static let collectionFolderBookmark = "collections.folderBookmark"
    static let collectionID = "collections.collectionID"
  }

  private let defaults: UserDefaults

  @Published var corner: OrbCorner {
    didSet { defaults.set(corner.rawValue, forKey: Keys.corner) }
  }

  @Published var orbSize: Double {
    didSet { defaults.set(orbSize, forKey: Keys.orbSize) }
  }

  @Published var isOrbVisible: Bool {
    didSet { defaults.set(isOrbVisible, forKey: Keys.isOrbVisible) }
  }

  @Published var isListening: Bool {
    didSet { defaults.set(isListening, forKey: Keys.isListening) }
  }

  @Published var voice: VoiceOption {
    didSet { defaults.set(voice.rawValue, forKey: Keys.voice) }
  }

  @Published var systemPrompt: String {
    didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) }
  }

  @Published var apiKey: String {
    didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
  }

  @Published var debugLogging: Bool {
    didSet {
      defaults.set(debugLogging, forKey: Keys.debugLogging)
      DebugLog.isEnabled = debugLogging
    }
  }

  @Published var primaryHotKey: HotKeyOption {
    didSet { defaults.set(primaryHotKey.rawValue, forKey: Keys.primaryHotKey) }
  }

  @Published var textAgentProvider: TextAgentProvider {
    didSet { defaults.set(textAgentProvider.rawValue, forKey: Keys.textAgentProvider) }
  }

  @Published var ollamaBaseURLString: String {
    didSet { defaults.set(ollamaBaseURLString, forKey: Keys.ollamaBaseURL) }
  }

  @Published var ollamaModel: String {
    didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) }
  }

  @Published var claudeCodeExecutablePath: String {
    didSet { defaults.set(claudeCodeExecutablePath, forKey: Keys.claudeCodeExecutablePath) }
  }

  @Published var codexExecutablePath: String {
    didSet { defaults.set(codexExecutablePath, forKey: Keys.codexExecutablePath) }
  }

  /// Comma-separated extra arguments passed before stdin (e.g. `exec,-`).
  @Published var claudeCodeArgumentsString: String {
    didSet { defaults.set(claudeCodeArgumentsString, forKey: Keys.claudeCodeArgumentsString) }
  }

  /// Comma-separated extra arguments for the Codex binary.
  @Published var codexArgumentsString: String {
    didSet { defaults.set(codexArgumentsString, forKey: Keys.codexArgumentsString) }
  }

  @Published var agentWorkingDirectoryPath: String {
    didSet { defaults.set(agentWorkingDirectoryPath, forKey: Keys.agentWorkingDirectoryPath) }
  }

  @Published var fileCollectionsEnabled: Bool {
    didSet { defaults.set(fileCollectionsEnabled, forKey: Keys.fileCollectionsEnabled) }
  }

  /// xAI Management API key — separate from the voice `apiKey`. Required for
  /// creating collections and uploading/attaching files at management-api.x.ai.
  @Published var xaiManagementAPIKey: String {
    didSet { defaults.set(xaiManagementAPIKey, forKey: Keys.xaiManagementAPIKey) }
  }

  /// Display path for the synced folder. Read-only access — actual filesystem
  /// access goes through the security-scoped `collectionFolderBookmark`.
  @Published var collectionFolderPath: String {
    didSet { defaults.set(collectionFolderPath, forKey: Keys.collectionFolderPath) }
  }

  /// Security-scoped bookmark for the synced folder. The sandbox requires this
  /// to keep access across launches — a plain path string isn't enough.
  @Published var collectionFolderBookmark: Data? {
    didSet {
      if let data = collectionFolderBookmark {
        defaults.set(data, forKey: Keys.collectionFolderBookmark)
      } else {
        defaults.removeObject(forKey: Keys.collectionFolderBookmark)
      }
    }
  }

  @Published var collectionID: String {
    didSet { defaults.set(collectionID, forKey: Keys.collectionID) }
  }

  /// Resolve the security-scoped bookmark back into a URL. Refreshes the stored
  /// bookmark if the OS reports it as stale. Returns nil if no bookmark or unresolvable.
  func resolveCollectionFolderURL() -> URL? {
    guard let data = collectionFolderBookmark else { return nil }
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      if isStale {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        if let refreshed = try? url.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        ) {
          collectionFolderBookmark = refreshed
        }
      }
      return url
    } catch {
      return nil
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    let savedCorner = defaults.string(forKey: Keys.corner) ?? OrbCorner.topRight.rawValue
    corner = OrbCorner(rawValue: savedCorner) ?? .topRight

    let savedSize = defaults.object(forKey: Keys.orbSize) as? Double
    orbSize = savedSize ?? 120

    isOrbVisible = defaults.object(forKey: Keys.isOrbVisible) as? Bool ?? true
    isListening = defaults.object(forKey: Keys.isListening) as? Bool ?? false

    let savedVoice = defaults.string(forKey: Keys.voice) ?? VoiceOption.ara.rawValue
    voice = VoiceOption(rawValue: savedVoice) ?? .ara

    systemPrompt =
      defaults.string(forKey: Keys.systemPrompt)
      ?? "You are Archibald, a concise desktop assistant."

    apiKey = defaults.string(forKey: Keys.apiKey) ?? ""

    debugLogging = defaults.object(forKey: Keys.debugLogging) as? Bool ?? true

    let savedHotKey = defaults.string(forKey: Keys.primaryHotKey)
      ?? HotKeyOption.optionBackslash.rawValue
    primaryHotKey = HotKeyOption(rawValue: savedHotKey) ?? .shiftBackslash

    let savedTextAgent = defaults.string(forKey: Keys.textAgentProvider) ?? TextAgentProvider.off.rawValue
    textAgentProvider = TextAgentProvider(rawValue: savedTextAgent) ?? .off

    ollamaBaseURLString =
      defaults.string(forKey: Keys.ollamaBaseURL) ?? "http://127.0.0.1:11434"
    ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "llama3.2"

    claudeCodeExecutablePath = defaults.string(forKey: Keys.claudeCodeExecutablePath) ?? ""
    codexExecutablePath = defaults.string(forKey: Keys.codexExecutablePath) ?? ""
    claudeCodeArgumentsString = defaults.string(forKey: Keys.claudeCodeArgumentsString) ?? ""
    codexArgumentsString = defaults.string(forKey: Keys.codexArgumentsString) ?? ""
    agentWorkingDirectoryPath = defaults.string(forKey: Keys.agentWorkingDirectoryPath) ?? ""

    fileCollectionsEnabled = defaults.object(forKey: Keys.fileCollectionsEnabled) as? Bool ?? false
    xaiManagementAPIKey = defaults.string(forKey: Keys.xaiManagementAPIKey) ?? ""
    collectionFolderPath = defaults.string(forKey: Keys.collectionFolderPath) ?? ""
    collectionFolderBookmark = defaults.data(forKey: Keys.collectionFolderBookmark)
    collectionID = defaults.string(forKey: Keys.collectionID) ?? ""

    DebugLog.isEnabled = debugLogging
  }

  static func commaSeparatedArguments(_ string: String) -> [String] {
    string.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
