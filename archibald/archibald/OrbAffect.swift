import Foundation

/// The character's emotional spine: a 2D affect state (arousal × valence) that motion
/// systems read instead of raw speech state. Baselines pull slowly toward what's
/// happening; events kick decaying transients on top.
final class OrbAffect {

  enum Event {
    case summoned
    case dismissed
    case userSpoke
    case agentSpoke
    case thinkingStarted
    case connectionLost
    case errorOccurred
  }

  /// 0 = asleep, 1 = electric.
  private(set) var arousal: Float = 0.45
  /// -1 = miserable, +1 = delighted.
  private(set) var valence: Float = 0.15
  private(set) var isAsleep = false

  private var arousalImpulse: Float = 0
  private var valenceImpulse: Float = 0
  /// Conversation-tone nudge from sentiment analysis, decays slowly.
  private var sentiment: Float = 0

  private static let sleepAfter: TimeInterval = 90

  func apply(event: Event) {
    switch event {
    case .summoned:
      arousalImpulse += isAsleep ? 0.75 : 0.4
      valenceImpulse += 0.3
    case .dismissed:
      valenceImpulse -= 0.35
    case .userSpoke:
      arousalImpulse += 0.15
    case .agentSpoke:
      arousalImpulse += 0.1
      valenceImpulse += 0.05
    case .thinkingStarted:
      arousalImpulse += 0.05
    case .connectionLost:
      arousalImpulse += 0.2
      valenceImpulse -= 0.7
    case .errorOccurred:
      valenceImpulse -= 0.45
    }
  }

  /// -1...1 from conversation sentiment; folded in as a slow mood tint.
  func setSentiment(_ score: Float) {
    sentiment = max(-1, min(1, score))
  }

  func update(
    deltaTime: TimeInterval,
    speechState: VoiceSessionManager.SpeechState,
    isListening: Bool,
    isConnectionFailed: Bool,
    idleTime: TimeInterval
  ) {
    let dt = Float(min(deltaTime, 1.0 / 30.0))

    let engaged = speechState != .idle || isListening
    isAsleep = !engaged && idleTime > Self.sleepAfter

    var baseArousal: Float
    switch speechState {
    case .userSpeaking: baseArousal = 0.8
    case .agentSpeaking: baseArousal = 0.65
    case .thinking: baseArousal = 0.55
    case .idle: baseArousal = isListening ? 0.75 : 0.35
    }
    if !engaged {
      // Long idle winds down toward drowsy, then sleep.
      let wind = Float(min(1.0, max(0.0, (idleTime - 20) / 70)))
      baseArousal -= wind * 0.3
      if isAsleep { baseArousal = 0.05 }
    }

    var baseValence: Float = 0.15 + sentiment * 0.4
    if isConnectionFailed { baseValence = min(baseValence, -0.5) }

    // Impulses decay; baselines are approached slowly (mood has inertia).
    let impulseDecay = expf(-dt * 0.8)
    arousalImpulse *= impulseDecay
    valenceImpulse *= impulseDecay
    sentiment *= expf(-dt * 0.03)

    let arousalTarget = max(0, min(1, baseArousal + arousalImpulse))
    let valenceTarget = max(-1, min(1, baseValence + valenceImpulse))
    // Arousal rises fast, falls slow; valence drifts.
    let arousalRate: Float = arousalTarget > arousal ? 2.2 : 0.35
    arousal += (arousalTarget - arousal) * min(1, dt * arousalRate)
    valence += (valenceTarget - valence) * min(1, dt * 0.9)
  }

  // MARK: - Derived dials

  /// Spring stiffness multiplier — the whole body moves at this tempo.
  var tempo: Float { 0.55 + arousal * 0.9 }
  /// Hover/breath cycle rate (rad/s) and depth (scene units).
  var breathRate: Float { 1.5 + arousal * 2.6 }
  var breathDepth: Float { 0.018 + (1 - arousal) * 0.014 }
  /// Blinks come faster when alert, slower and heavier when winding down.
  var blinkRateMultiplier: Float { 0.55 + arousal * 0.8 }
  /// Partial eyelid droop as arousal bottoms out (drowsy look before sleep).
  var lidDroop: Float { max(0, (0.28 - arousal) / 0.28) * 0.5 }
  var fidgetEnergy: Float { arousal }
  /// 0...1 brightness/saturation lift from mood; negative valence dims the body color.
  var moodBrightness: Float { 0.72 + 0.28 * ((valence + 1) / 2) }
  /// 0...1 how sad the brows should sit.
  var browSadness: Float { max(0, -valence) }
}
