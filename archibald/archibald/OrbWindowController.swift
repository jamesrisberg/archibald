import AppKit
import Combine
import QuartzCore
import SwiftUI

/// nonactivatingPanel never becomes key on click, so every mouseDown is a "first click"
/// on a non-key window — AppKit drops those unless the hit view returns true from
/// `acceptsFirstMouse:`. Default NSHostingView's hit-test also defers to SwiftUI, which
/// reports no hit when the only content is a pass-through SCNView. This subclass
/// solves both: always claims the hit, accepts first-mouse, handles click directly.
private final class OrbHostingView<Content: View>: NSHostingView<Content> {
  var onClick: (() -> Void)?

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }
}

final class OrbWindowController {
  private let panel: NSPanel
  private let settings: AppSettings
  private let voiceSession: VoiceSessionManager
  private let orbWalkFacing: OrbWalkFacing
  private var cancellables = Set<AnyCancellable>()
  private var yawAnimationTimer: Timer?
  /// Generation token: each show/hide bumps it. The async completion handler
  /// from a previous transition checks against this and bails if superseded —
  /// without this, a hide's `orderOut` can fire on top of a fresh show.
  private var transitionGeneration: Int = 0

  /// How far past the edge the orb rests before sliding in (pt).
  private static let slideDistanceBase: CGFloat = 130

  private static let entranceDuration: TimeInterval = 0.52
  private static let exitDuration: TimeInterval = 0.38

  init(settings: AppSettings, voiceSession: VoiceSessionManager, orbWalkFacing: OrbWalkFacing) {
    self.settings = settings
    self.voiceSession = voiceSession
    self.orbWalkFacing = orbWalkFacing

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
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true

    let rootView = OrbView(orbWalkFacing: orbWalkFacing)
      .environmentObject(settings)
      .environmentObject(voiceSession)
    let hostingView = OrbHostingView(rootView: rootView)
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.onClick = { [weak settings] in
      settings?.isListening.toggle()
    }
    panel.contentView = hostingView

    updateFrame()
    bindSettings()
  }

  func setVisible(_ isVisible: Bool) {
    if isVisible {
      showWithEntranceAnimation()
    } else {
      hideWithExitAnimation()
    }
  }

  func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()
  }

  private func showWithEntranceAnimation() {
    transitionGeneration &+= 1
    yawAnimationTimer?.invalidate()

    let rest = restFrame()
    let alreadyAtRest = panel.isVisible
      && abs(panel.frame.minX - rest.minX) < 1
      && abs(panel.frame.minY - rest.minY) < 1
    if alreadyAtRest {
      bringToFront()
      return
    }

    let outward = outwardYawRadians()
    let inward = inwardYawRadians()

    // If we're starting cold (hidden), snap to off-screen first.
    // If we're catching a mid-flight exit, animate from current position so
    // the orb doesn't teleport before sliding in.
    if !panel.isVisible {
      orbWalkFacing.yawRadians = outward
      let off = offScreenFrame(rest: rest)
      panel.setFrame(off, display: true)
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()

    runEntranceYawAnimation(outward: outward, inward: inward, duration: Self.entranceDuration)

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Self.entranceDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(rest, display: true)
    })
  }

  private func hideWithExitAnimation() {
    transitionGeneration &+= 1
    let generation = transitionGeneration

    guard panel.isVisible else {
      panel.orderOut(nil)
      return
    }

    let outward = outwardYawRadians()
    let startYaw = orbWalkFacing.yawRadians

    let rest = restFrame()
    let off = offScreenFrame(rest: rest)

    runYawAnimation(
      from: startYaw,
      to: outward,
      duration: Self.exitDuration,
      easeOut: false
    )

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Self.exitDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().setFrame(off, display: true)
    }, completionHandler: { [weak self] in
      guard let self else { return }
      // A newer show/hide has happened — don't tear the panel out from under it.
      if self.transitionGeneration != generation { return }
      self.orbWalkFacing.yawRadians = outward
      self.panel.orderOut(nil)
    })
  }

  /// Horizontal rotation (Y) so the orb faces toward the desktop center (walking “in”).
  private func inwardYawRadians() -> CGFloat {
    guard let screen = NSScreen.main?.visibleFrame else { return 0 }
    let center = CGPoint(x: screen.midX, y: screen.midY)
    let outer = OrbLayout.outerSize(orbSize: settings.orbSize)
    let orbCenter: CGPoint
    switch settings.corner {
    case .topLeft:
      orbCenter = CGPoint(x: screen.minX + outer * 0.5, y: screen.maxY - outer * 0.5)
    case .topRight:
      orbCenter = CGPoint(x: screen.maxX - outer * 0.5, y: screen.maxY - outer * 0.5)
    case .bottomLeft:
      orbCenter = CGPoint(x: screen.minX + outer * 0.5, y: screen.minY + outer * 0.5)
    case .bottomRight:
      orbCenter = CGPoint(x: screen.maxX - outer * 0.5, y: screen.minY + outer * 0.5)
    }
    let dx = center.x - orbCenter.x
    let angle = atan2(-dx, max(120, screen.height * 0.28))
    return max(-0.62, min(0.62, angle * 0.72))
  }

  /// Faces toward the corner / off-screen (walking “out”).
  private func outwardYawRadians() -> CGFloat {
    -inwardYawRadians()
  }

  /// First faces inward (toward screen center), then eases to neutral so he looks at you while idle.
  private func runEntranceYawAnimation(outward: CGFloat, inward: CGFloat, duration: TimeInterval) {
    yawAnimationTimer?.invalidate()
    let startTime = CACurrentMediaTime()
    let phaseCut: CGFloat = 0.58
    yawAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) {
      [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      let elapsed = CACurrentMediaTime() - startTime
      let t = min(1, CGFloat(elapsed / duration))
      let yaw: CGFloat
      if t < phaseCut {
        let u = t / phaseCut
        let s = 1 - pow(1 - u, 3)
        yaw = outward + (inward - outward) * s
      } else {
        let u = (t - phaseCut) / (1 - phaseCut)
        let s = Self.easeInOutCubic(u)
        yaw = inward + (0 - inward) * s
      }
      self.orbWalkFacing.yawRadians = yaw
      if t >= 1 {
        timer.invalidate()
        self.orbWalkFacing.yawRadians = 0
      }
    }
    RunLoop.main.add(yawAnimationTimer!, forMode: .common)
  }

  private func runYawAnimation(
    from: CGFloat,
    to: CGFloat,
    duration: TimeInterval,
    easeOut: Bool
  ) {
    yawAnimationTimer?.invalidate()
    let startTime = CACurrentMediaTime()
    let delta = to - from
    yawAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) {
      [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      let elapsed = CACurrentMediaTime() - startTime
      let t = min(1, CGFloat(elapsed / duration))
      let s: CGFloat
      if easeOut {
        s = 1 - pow(1 - t, 3)
      } else {
        s = t * t * t
      }
      self.orbWalkFacing.yawRadians = from + delta * s
      if t >= 1 {
        timer.invalidate()
        self.orbWalkFacing.yawRadians = to
      }
    }
    RunLoop.main.add(yawAnimationTimer!, forMode: .common)
  }

  private static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
  }

  deinit {
    yawAnimationTimer?.invalidate()
  }

  private func offScreenFrame(rest: NSRect) -> NSRect {
    let slide = max(Self.slideDistanceBase, rest.width * 0.65)
    let dx: CGFloat
    let dy: CGFloat
    switch settings.corner {
    case .topLeft: dx = -slide; dy = slide
    case .topRight: dx = slide; dy = slide
    case .bottomLeft: dx = -slide; dy = -slide
    case .bottomRight: dx = slide; dy = -slide
    }
    return rest.offsetBy(dx: dx, dy: dy)
  }

  private func restFrame() -> NSRect {
    guard let screen = NSScreen.main?.visibleFrame else {
      return panel.frame
    }

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

    return NSRect(origin: origin, size: CGSize(width: size, height: size))
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
    let rest = restFrame()
    if panel.isVisible {
      panel.setFrame(rest, display: true)
    } else {
      panel.setFrame(offScreenFrame(rest: rest), display: true)
      orbWalkFacing.yawRadians = outwardYawRadians()
    }
  }
}
