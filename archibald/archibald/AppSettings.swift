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

  private enum Keys {
    static let corner = "orb.corner"
    static let orbSize = "orb.size"
    static let isOrbVisible = "orb.visible"
    static let isListening = "orb.listening"
    static let voice = "voice.selected"
    static let systemPrompt = "voice.systemPrompt"
    static let tokenEndpoint = "voice.tokenEndpoint"
    static let apiKey = "voice.apiKey"
    static let inboxFolderPath = "context.inboxFolderPath"
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

  @Published var tokenEndpoint: String {
    didSet { defaults.set(tokenEndpoint, forKey: Keys.tokenEndpoint) }
  }

  @Published var apiKey: String {
    didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
  }

  @Published var inboxFolderPath: String {
    didSet { defaults.set(inboxFolderPath, forKey: Keys.inboxFolderPath) }
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

    tokenEndpoint =
      defaults.string(forKey: Keys.tokenEndpoint)
      ?? "http://localhost:8081/session"

    apiKey = defaults.string(forKey: Keys.apiKey) ?? ""

    inboxFolderPath = defaults.string(forKey: Keys.inboxFolderPath) ?? ""
  }
}
