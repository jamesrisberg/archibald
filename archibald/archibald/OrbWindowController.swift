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

    let outerSize = OrbLayout.outerSize(orbSize: settings.orbSize)
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: outerSize, height: outerSize),
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
    panel.level = .normal
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true

    let rootView = OrbView()
      .environmentObject(settings)
      .environmentObject(voiceSession)
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    panel.contentView = hostingView

    updateFrame()
    bindSettings()
  }

  func setVisible(_ isVisible: Bool) {
    if isVisible {
      bringToFront()
    } else {
      panel.orderOut(nil)
    }
  }

  func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()
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

    let size = OrbLayout.outerSize(orbSize: settings.orbSize)
    let padding: CGFloat = 0
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
