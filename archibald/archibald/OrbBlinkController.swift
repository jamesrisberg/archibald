import Foundation

/// Stochastic blinking. Real blinks close fast (~70ms), hold briefly, open slower (~130ms);
/// intervals are irregular (2–6.5s scaled by arousal) with occasional double-blinks.
/// Output is 0 (open) ... 1 (closed); sleep overrides with a slow full closure.
final class OrbBlinkController {

  private enum Phase {
    case open
    case closing
    case closed
    case opening
  }

  private var phase: Phase = .open
  private var phaseTime: TimeInterval = 0
  private var timeToNextBlink: TimeInterval = 2.5
  private var doubleBlinkPending = false
  private var envelope: Float = 0
  private var sleepLid: Float = 0

  private static let closeDuration: TimeInterval = 0.07
  private static let holdDuration: TimeInterval = 0.045
  private static let openDuration: TimeInterval = 0.13

  /// Event blink (gaze shift, expression change). Ignored mid-blink.
  func requestBlink() {
    guard phase == .open else { return }
    beginBlink()
  }

  func update(deltaTime: TimeInterval, arousal: Float, isAsleep: Bool) -> Float {
    let dt = min(deltaTime, 1.0 / 30.0)

    // Sleep closes the lids slowly and suppresses blinking.
    let sleepTarget: Float = isAsleep ? 1 : 0
    sleepLid += (sleepTarget - sleepLid) * Float(min(1, dt * (isAsleep ? 1.6 : 3.0)))

    if isAsleep {
      phase = .open
      envelope = 0
      return sleepLid
    }

    phaseTime += dt
    switch phase {
    case .open:
      timeToNextBlink -= dt
      if timeToNextBlink <= 0 {
        beginBlink()
      }
    case .closing:
      envelope = Float(min(1, phaseTime / Self.closeDuration))
      if phaseTime >= Self.closeDuration {
        phase = .closed
        phaseTime = 0
      }
    case .closed:
      envelope = 1
      if phaseTime >= Self.holdDuration {
        phase = .opening
        phaseTime = 0
      }
    case .opening:
      envelope = Float(max(0, 1 - phaseTime / Self.openDuration))
      if phaseTime >= Self.openDuration {
        phase = .open
        phaseTime = 0
        envelope = 0
        if doubleBlinkPending {
          doubleBlinkPending = false
          timeToNextBlink = 0.18
        } else {
          scheduleNextBlink(arousal: arousal)
        }
      }
    }

    return max(envelope, sleepLid)
  }

  private func beginBlink() {
    phase = .closing
    phaseTime = 0
    if Double.random(in: 0...1) < 0.12 {
      doubleBlinkPending = true
    }
  }

  private func scheduleNextBlink(arousal: Float) {
    let rate = Double(max(0.35, 0.55 + arousal * 0.8))
    timeToNextBlink = Double.random(in: 2.0...6.5) / rate
  }
}
