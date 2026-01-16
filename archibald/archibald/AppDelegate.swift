import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var settings: AppSettings?
  weak var voiceSession: VoiceSessionManager?
  private var orbWindowController: OrbWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let settings, let voiceSession else { return }
    let controller = OrbWindowController(settings: settings, voiceSession: voiceSession)
    orbWindowController = controller
    controller.setVisible(settings.isOrbVisible)
  }

  func applicationWillTerminate(_ notification: Notification) {
    orbWindowController = nil
  }
}
