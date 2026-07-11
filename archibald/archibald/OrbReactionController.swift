import Foundation

final class OrbReactionController {

  enum Reaction {
    case summoned
    case userStartedSpeaking
    case agentStartedSpeaking
    case conversationEnded
    case dismissed
    case connectionLost
  }

  struct ReactionOutput {
    var scaleMultiplier: Float = 1.0
    var positionOffset = SIMD3<Float>(0, 0, 0)
    var rotationOffset = SIMD3<Float>(0, 0, 0)
    var eyeExpression: OrbEyes.Expression?
  }

  private var activeReaction: Reaction?
  private var reactionStartTime: TimeInterval = 0
  private var reactionDuration: TimeInterval = 0
  /// Reactions whose curves end on a held pose (lean, droop) release back to rest
  /// over this window instead of snapping to zero on expiry.
  private static let releaseDuration: TimeInterval = 0.22
  private var releasing = false
  private var releaseStartTime: TimeInterval = 0
  private var releaseSnapshot = ReactionOutput()

  func trigger(_ reaction: Reaction, at time: TimeInterval) {
    activeReaction = reaction
    reactionStartTime = time
    reactionDuration = durationFor(reaction)
    releasing = false
  }

  func update(currentTime: TimeInterval) -> ReactionOutput {
    if releasing {
      return updateRelease(currentTime: currentTime)
    }

    guard let reaction = activeReaction else {
      return ReactionOutput()
    }

    let elapsed = currentTime - reactionStartTime
    let t = Float(min(1.0, elapsed / reactionDuration))

    if t >= 1.0 {
      // Hand the final pose to the release phase so held curves ease home.
      releaseSnapshot = outputFor(reaction, progress: 1.0)
      releaseSnapshot.eyeExpression = nil
      activeReaction = nil
      releasing = true
      releaseStartTime = currentTime
      return updateRelease(currentTime: currentTime)
    }

    return outputFor(reaction, progress: t)
  }

  var isActive: Bool {
    activeReaction != nil || releasing
  }

  // MARK: - Private

  private func updateRelease(currentTime: TimeInterval) -> ReactionOutput {
    let t = Float(min(1.0, (currentTime - releaseStartTime) / Self.releaseDuration))
    if t >= 1.0 {
      releasing = false
      return ReactionOutput()
    }
    let ease = 1 - (1 - t) * (1 - t)  // Ease-out back to rest.
    var output = ReactionOutput()
    output.scaleMultiplier = releaseSnapshot.scaleMultiplier + (1 - releaseSnapshot.scaleMultiplier) * ease
    output.positionOffset = releaseSnapshot.positionOffset * (1 - ease)
    output.rotationOffset = releaseSnapshot.rotationOffset * (1 - ease)
    return output
  }

  private func durationFor(_ reaction: Reaction) -> TimeInterval {
    switch reaction {
    case .summoned: return 0.5
    case .userStartedSpeaking: return 0.3
    case .agentStartedSpeaking: return 0.4
    case .conversationEnded: return 0.6
    case .dismissed: return 0.25
    case .connectionLost: return 0.7
    }
  }

  private func outputFor(_ reaction: Reaction, progress t: Float) -> ReactionOutput {
    var output = ReactionOutput()
    let pi = Float.pi

    switch reaction {
    case .summoned:
      // Excited bounce up + scale pop
      let bounce = sin(t * pi) * 0.04
      let scalePop = 1.0 + sin(t * pi) * 0.05
      output.positionOffset.y = bounce
      output.scaleMultiplier = scalePop
      output.eyeExpression = .wide

    case .userStartedSpeaking:
      // Lean in (tilt forward) + slight scale up
      let leanCurve = sin(t * pi / 2)  // Ease in, stays leaned
      output.rotationOffset.x = -0.05 * leanCurve
      output.scaleMultiplier = 1.0 + 0.02 * leanCurve
      output.eyeExpression = .wide

    case .agentStartedSpeaking:
      // Two subtle nods
      let nod = sin(t * pi * 2) * 0.015
      output.positionOffset.y = abs(nod)

    case .conversationEnded:
      // Small satisfied bounce then settle
      let settle: Float
      if t < 0.4 {
        settle = sin(t / 0.4 * pi) * 0.02
      } else {
        settle = sin((t - 0.4) / 0.6 * pi / 2) * 0.005
      }
      output.positionOffset.y = settle

    case .dismissed:
      // Sad droop downward + slight shrink
      let droopCurve = sin(t * pi / 2)  // Ease in
      output.positionOffset.y = -0.03 * droopCurve
      output.scaleMultiplier = 1.0 - 0.05 * droopCurve
      output.eyeExpression = .drowsy

    case .connectionLost:
      // Confused little head-shake, decaying, with a droop settling in.
      let decay = 1 - t
      output.rotationOffset.z = sin(t * pi * 3) * 0.055 * decay
      output.positionOffset.y = -0.02 * sin(t * pi / 2)
      output.eyeExpression = .wide
    }

    return output
  }
}
