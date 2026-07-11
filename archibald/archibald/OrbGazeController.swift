import Foundation
import simd

/// Gaze with manners. Instead of perpetually tracking the cursor at max deflection
/// (surveillance), the orb holds mutual gaze for a few seconds, politely looks away,
/// and re-engages. Fixations move as saccades (instant jumps) with micro-jitter,
/// not smooth pursuit. Modes shape the pattern: thinking looks up-and-aside,
/// sleepy sinks, attentive rarely averts.
final class OrbGazeController {

  enum Mode {
    case idle
    case attentive  // listening / user speaking
    case conversational  // agent speaking
    case thoughtful  // waiting on a response
    case sleepy
  }

  struct GazeFrame {
    /// Target in ±1 pupil-range units.
    var target = SIMD2<Float>(0, 0)
    /// True when the fixation just jumped — apply instantly, and it's a natural blink moment.
    var saccade = false
  }

  private var engaged = true
  private var stateTimer: TimeInterval = 0
  private var stateDuration: TimeInterval = 3
  private var aversionTarget = SIMD2<Float>(0, 0)
  private var fixation = SIMD2<Float>(0, 0)
  private var microSaccadeTimer: TimeInterval = 0.6
  private var microJitter = SIMD2<Float>(0, 0)
  private var thoughtfulSide: Float = 1
  private var previousMode: Mode = .idle

  func update(
    deltaTime: TimeInterval,
    mode: Mode,
    cursor: SIMD2<Float>?,
    arousal: Float
  ) -> GazeFrame {
    let dt = min(deltaTime, 1.0 / 30.0)
    var frame = GazeFrame()

    if mode != previousMode {
      previousMode = mode
      stateTimer = 0
      stateDuration = 0  // Force an immediate re-decision in the new mode.
      frame.saccade = true
    }

    stateTimer += dt
    microSaccadeTimer -= dt

    switch mode {
    case .sleepy:
      // Lids are closing anyway; gaze settles low and stays.
      fixation = SIMD2<Float>(0, -0.6)
      frame.target = fixation
      return frame

    case .thoughtful:
      // Classic recall gaze: up and to one side, switching sides occasionally.
      if stateTimer >= stateDuration {
        stateTimer = 0
        stateDuration = Double.random(in: 1.8...3.4)
        thoughtfulSide = Bool.random() ? thoughtfulSide : -thoughtfulSide
        fixation = SIMD2<Float>(0.55 * thoughtfulSide, 0.72)
        frame.saccade = true
      }

    case .attentive, .conversational, .idle:
      // Engage/avert cycle. Attentive holds gaze much longer between aversions.
      if stateTimer >= stateDuration {
        stateTimer = 0
        engaged.toggle()
        frame.saccade = true
        if engaged {
          switch mode {
          case .attentive: stateDuration = Double.random(in: 4.0...7.0)
          case .conversational: stateDuration = Double.random(in: 3.0...5.0)
          default: stateDuration = Double.random(in: 2.0...4.5)
          }
        } else {
          stateDuration =
            mode == .attentive
            ? Double.random(in: 0.5...1.0)
            : Double.random(in: 0.9...2.2)
          // Look away low-left or low-right — reads as thought, not rejection.
          aversionTarget = SIMD2<Float>(
            Float.random(in: 0.35...0.7) * (Bool.random() ? 1 : -1),
            Float.random(in: -0.5 ... -0.1)
          )
        }
      }

      if engaged {
        let interest = cursor.map { c in
          SIMD2<Float>(max(-1, min(1, c.x)), max(-1, min(1, c.y)))
        } ?? SIMD2<Float>(0, 0)
        // Saccadic fixation: only re-fixate when the target has drifted far enough.
        if simd_distance(interest, fixation) > 0.22 {
          fixation = interest
          frame.saccade = true
        }
      } else {
        fixation = aversionTarget
      }
    }

    // Micro-saccades: tiny fixational jitter, more frequent when alert.
    if microSaccadeTimer <= 0 {
      microSaccadeTimer = Double.random(in: 0.35...1.3) / Double(max(0.4, 0.5 + arousal))
      microJitter = SIMD2<Float>(
        Float.random(in: -0.045...0.045),
        Float.random(in: -0.045...0.045)
      )
    }

    frame.target = fixation + microJitter
    return frame
  }
}
