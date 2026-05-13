import AppKit
import Combine
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var settings: AppSettings?
  weak var voiceSession: VoiceSessionManager?
  weak var collectionSync: CollectionSyncEngine?
  private var orbWindowController: OrbWindowController?
  private let hotKeyManager = GlobalHotKeyManager()
  private var cancellables = Set<AnyCancellable>()

  let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let settings, let voiceSession else { return }
    settings.isListening = false
    let orbWalkFacing = OrbWalkFacing()
    let controller = OrbWindowController(
      settings: settings, voiceSession: voiceSession, orbWalkFacing: orbWalkFacing)
    orbWindowController = controller
    controller.setVisible(settings.isOrbVisible)

    hotKeyManager.onPrimary = {
      if !settings.isOrbVisible {
        // Let the visibility sink drive the entrance animation; calling
        // bringToFront() here would prematurely make the panel visible at its
        // off-screen frame and short-circuit the slide-in.
        settings.isOrbVisible = true
        settings.isListening = true
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
    settings?.isListening = false
    orbWindowController = nil
    hotKeyManager.stop()
  }
}
