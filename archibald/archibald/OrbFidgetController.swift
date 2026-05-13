import Foundation
import simd

final class OrbFidgetController {

  enum Fidget {
    case microTilt
    case lookAround
    case smallBounce
    case curiousTilt
    case slowSpin
  }

  struct FidgetOutput {
    var rotationOffset = SIMD3<Float>(0, 0, 0)
    var positionOffset = SIMD3<Float>(0, 0, 0)
    var eyeGazeOverride: SIMD2<Float>?
  }

  private var idleTime: TimeInterval = 0
  private var fidgetCooldown: TimeInterval = 0
  private var activeFidget: Fidget?
  private var fidgetStartTime: TimeInterval = 0
  private var fidgetDuration: TimeInterval = 0
  private var fidgetSeed: Float = 0  // Random parameter for variation

  // Smooth interruption
  private var currentOutput = FidgetOutput()
  private var isInterrupting = false

  func update(deltaTime: TimeInterval, isIdle: Bool, currentTime: TimeInterval) -> FidgetOutput {
    if !isIdle {
      if activeFidget != nil || currentOutput.hasNonZeroValues {
        isInterrupting = true
        activeFidget = nil
      }
      idleTime = 0
      fidgetCooldown = 0

      if isInterrupting {
        return smoothReturnToZero(deltaTime: deltaTime)
      }
      return FidgetOutput()
    }

    isInterrupting = false
    idleTime += deltaTime
    fidgetCooldown -= deltaTime

    // Don't fidget until idle for 3+ seconds
    guard idleTime > 3.0 else { return currentOutput }

    // If no active fidget and cooldown expired, start one
    if activeFidget == nil && fidgetCooldown <= 0 {
      startRandomFidget(at: currentTime)
    }

    // Compute current fidget frame
    if let fidget = activeFidget {
      let elapsed = currentTime - fidgetStartTime
      let t = Float(min(1.0, elapsed / fidgetDuration))

      if t >= 1.0 {
        activeFidget = nil
        fidgetCooldown = Double.random(in: 5.0...15.0)
        currentOutput = FidgetOutput()
        return currentOutput
      }

      currentOutput = outputForFidget(fidget, progress: t)
    }

    return currentOutput
  }

  // MARK: - Private

  private func startRandomFidget(at time: TimeInterval) {
    activeFidget = weightedRandomFidget()
    fidgetStartTime = time
    fidgetDuration = durationForFidget(activeFidget!)
    fidgetSeed = Float.random(in: -1...1)
  }

  private func weightedRandomFidget() -> Fidget {
    let roll = Double.random(in: 0...1)
    if roll < 0.40 { return .microTilt }
    if roll < 0.70 { return .lookAround }
    if roll < 0.85 { return .smallBounce }
    if roll < 0.95 { return .curiousTilt }
    return .slowSpin
  }

  private func durationForFidget(_ fidget: Fidget) -> TimeInterval {
    switch fidget {
    case .microTilt: return Double.random(in: 1.5...2.5)
    case .lookAround: return 2.0
    case .smallBounce: return 0.8
    case .curiousTilt: return 2.0
    case .slowSpin: return 3.5
    }
  }

  private func outputForFidget(_ fidget: Fidget, progress t: Float) -> FidgetOutput {
    var output = FidgetOutput()
    let pi = Float.pi

    switch fidget {
    case .microTilt:
      // Gentle tilt on a random axis, sine curve (goes out and returns)
      let angle = sin(t * pi) * Float.random(in: 0.035...0.09)
      if fidgetSeed > 0 {
        output.rotationOffset.x = angle
      } else {
        output.rotationOffset.z = angle
      }

    case .lookAround:
      // Eyes sweep left, pause, sweep right, return to center
      let g = OrbEyes.maxPupilOffset
      let gazeX: Float
      if t < 0.25 {
        gazeX = -sin(t / 0.25 * pi / 2) * g
      } else if t < 0.5 {
        gazeX = -g
      } else if t < 0.75 {
        gazeX = -g + sin((t - 0.5) / 0.25 * pi / 2) * (2 * g)
      } else {
        gazeX = g - sin((t - 0.75) / 0.25 * pi / 2) * g
      }
      output.eyeGazeOverride = SIMD2<Float>(gazeX, 0)

    case .smallBounce:
      // Two quick bounces using absolute sine
      let bounceHeight: Float = 0.03
      output.positionOffset.y = abs(sin(t * pi * 2)) * bounceHeight

    case .curiousTilt:
      // Tilt head to one side, hold briefly, return
      let tiltAngle: Float = 0.08 * fidgetSeed.sign
      if t < 0.3 {
        output.rotationOffset.z = sin(t / 0.3 * pi / 2) * tiltAngle
      } else if t < 0.7 {
        output.rotationOffset.z = tiltAngle
      } else {
        output.rotationOffset.z = tiltAngle * (1.0 - sin((t - 0.7) / 0.3 * pi / 2))
      }

    case .slowSpin:
      // Wind-up (anticipation) → fast sweep → overshoot past 2π → settle.
      let twoPi = 2 * pi
      let anticipation: Float = -0.44
      let overshootPast: Float = 0.32
      let tAnticipationEnd: Float = 0.13
      let tSpinEnd: Float = 0.80

      if t < tAnticipationEnd {
        let u = t / tAnticipationEnd
        let eased = 1 - (1 - u) * (1 - u)
        output.rotationOffset.y = eased * anticipation
      } else if t < tSpinEnd {
        let u = (t - tAnticipationEnd) / (tSpinEnd - tAnticipationEnd)
        let p = 1 - (1 - u) * (1 - u) * (1 - u)
        let start = anticipation
        let end = twoPi + overshootPast
        output.rotationOffset.y = start + p * (end - start)
      } else {
        let u = (t - tSpinEnd) / (1 - tSpinEnd)
        let eased = 1 - (1 - u) * (1 - u) * (1 - u)
        let start = twoPi + overshootPast
        output.rotationOffset.y = start + eased * (twoPi - start)
      }
    }

    return output
  }

  private func smoothReturnToZero(deltaTime: TimeInterval) -> FidgetOutput {
    let speed = Float(deltaTime * 5.0)
    currentOutput.rotationOffset *= (1.0 - speed)
    currentOutput.positionOffset *= (1.0 - speed)

    // Check if close enough to zero
    let magnitude =
      simd_length(currentOutput.rotationOffset) + simd_length(currentOutput.positionOffset)
    if magnitude < 0.001 {
      currentOutput = FidgetOutput()
      isInterrupting = false
    }

    return currentOutput
  }
}

extension OrbFidgetController.FidgetOutput {
  var hasNonZeroValues: Bool {
    simd_length(rotationOffset) > 0.001 || simd_length(positionOffset) > 0.001
      || eyeGazeOverride != nil
  }
}

extension Float {
  fileprivate var sign: Float {
    self >= 0 ? 1.0 : -1.0
  }
}
