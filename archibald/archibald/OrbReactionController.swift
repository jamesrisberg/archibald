import Foundation

final class OrbReactionController {

  enum Reaction {
    case summoned
    case userStartedSpeaking
    case agentStartedSpeaking
    case conversationEnded
    case dismissed
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

  func trigger(_ reaction: Reaction, at time: TimeInterval) {
    activeReaction = reaction
    reactionStartTime = time
    reactionDuration = durationFor(reaction)
  }

  func update(currentTime: TimeInterval) -> ReactionOutput {
    guard let reaction = activeReaction else {
      return ReactionOutput()
    }

    let elapsed = currentTime - reactionStartTime
    let t = Float(min(1.0, elapsed / reactionDuration))

    if t >= 1.0 {
      activeReaction = nil
      return ReactionOutput()
    }

    return outputFor(reaction, progress: t)
  }

  var isActive: Bool {
    activeReaction != nil
  }

  // MARK: - Private

  private func durationFor(_ reaction: Reaction) -> TimeInterval {
    switch reaction {
    case .summoned: return 0.5
    case .userStartedSpeaking: return 0.3
    case .agentStartedSpeaking: return 0.4
    case .conversationEnded: return 0.6
    case .dismissed: return 0.25
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
    }

    return output
  }
}
