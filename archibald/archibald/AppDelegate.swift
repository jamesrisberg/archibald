import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var settings: AppSettings?
  weak var voiceSession: VoiceSessionManager?
  private var orbWindowController: OrbWindowController?
  private let hotKeyManager = GlobalHotKeyManager()
  private var cancellables = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let settings, let voiceSession else { return }
    settings.isListening = false
    let controller = OrbWindowController(settings: settings, voiceSession: voiceSession)
    orbWindowController = controller
    controller.setVisible(settings.isOrbVisible)

    hotKeyManager.onPrimary = {
      if !settings.isOrbVisible {
        settings.isOrbVisible = true
        settings.isListening = true
        controller.bringToFront()
      } else {
        controller.bringToFront()
        settings.isListening.toggle()
      }
    }
    hotKeyManager.onHide = {
      settings.isOrbVisible = false
      settings.isListening = false
    }
    hotKeyManager.updatePrimaryHotKey(settings.primaryHotKey)
    hotKeyManager.start()

    settings.$primaryHotKey
      .receive(on: RunLoop.main)
      .sink { [weak self] (option: AppSettings.HotKeyOption) in
        self?.hotKeyManager.updatePrimaryHotKey(option)
      }
      .store(in: &cancellables)
  }

  func applicationWillTerminate(_ notification: Notification) {
    orbWindowController = nil
    hotKeyManager.stop()
  }
}
