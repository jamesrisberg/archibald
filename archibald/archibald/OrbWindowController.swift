import AppKit
import Combine
import SwiftUI

final class OrbWindowController {
  private let panel: NSPanel
  private let settings: AppSettings
  private let voiceSession: VoiceSessionManager
  private var cancellables = Set<AnyCancellable>()

  init(settings: AppSettings, voiceSession: VoiceSessionManager) {
    self.settings = settings
    self.voiceSession = voiceSession

    let styleMask: NSWindow.StyleMask = [
      .borderless,
      .nonactivatingPanel,
    ]

    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: settings.orbSize, height: settings.orbSize),
      styleMask: styleMask,
      backing: .buffered,
      defer: false
    )

    panel.isFloatingPanel = true
    panel.isMovable = false
    panel.ignoresMouseEvents = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true

    let rootView = OrbView()
      .environmentObject(settings)
      .environmentObject(voiceSession)
    panel.contentView = NSHostingView(rootView: rootView)

    updateFrame()
    bindSettings()
  }

  func setVisible(_ isVisible: Bool) {
    if isVisible {
      panel.orderFrontRegardless()
    } else {
      panel.orderOut(nil)
    }
  }

  private func bindSettings() {
    settings.$corner
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateFrame() }
      .store(in: &cancellables)

    settings.$orbSize
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.updateFrame() }
      .store(in: &cancellables)

    settings.$isOrbVisible
      .receive(on: RunLoop.main)
      .sink { [weak self] isVisible in self?.setVisible(isVisible) }
      .store(in: &cancellables)
  }

  private func updateFrame() {
    guard let screen = NSScreen.main?.visibleFrame else { return }

    let size = settings.orbSize
    let padding: CGFloat = 16
    let origin: CGPoint

    switch settings.corner {
    case .topLeft:
      origin = CGPoint(
        x: screen.minX + padding,
        y: screen.maxY - size - padding
      )
    case .topRight:
      origin = CGPoint(
        x: screen.maxX - size - padding,
        y: screen.maxY - size - padding
      )
    case .bottomLeft:
      origin = CGPoint(
        x: screen.minX + padding,
        y: screen.minY + padding
      )
    case .bottomRight:
      origin = CGPoint(
        x: screen.maxX - size - padding,
        y: screen.minY + padding
      )
    }

    panel.setFrame(NSRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
  }
}
