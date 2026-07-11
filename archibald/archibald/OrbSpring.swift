import Foundation
import simd

/// Damped spring toward a movable target. Semi-implicit Euler, stable at animation dt.
/// Stiffness/damping are the emotion dial: scale `tempo` up for sprightly, down for sleepy.
struct OrbSpring {
  var value: Float
  var velocity: Float = 0
  var target: Float
  /// ω² term — higher is snappier.
  var stiffness: Float
  /// 1 = critical, <1 overshoots (alive), >1 sluggish.
  var dampingRatio: Float

  init(value: Float, stiffness: Float = 90, dampingRatio: Float = 0.82) {
    self.value = value
    self.target = value
    self.stiffness = stiffness
    self.dampingRatio = dampingRatio
  }

  mutating func update(deltaTime: TimeInterval, tempo: Float = 1) {
    let dt = Float(min(deltaTime, 1.0 / 30.0))
    let k = stiffness * max(0.05, tempo)
    let c = 2 * sqrt(k) * dampingRatio
    velocity += (k * (target - value) - c * velocity) * dt
    value += velocity * dt
  }

  /// Snap to target with no motion — used for saccades.
  mutating func jump() {
    value = target
    velocity = 0
  }
}

struct OrbSpring2 {
  var value: SIMD2<Float>
  var velocity = SIMD2<Float>(0, 0)
  var target: SIMD2<Float>
  var stiffness: Float
  var dampingRatio: Float

  init(value: SIMD2<Float>, stiffness: Float = 90, dampingRatio: Float = 0.82) {
    self.value = value
    self.target = value
    self.stiffness = stiffness
    self.dampingRatio = dampingRatio
  }

  mutating func update(deltaTime: TimeInterval, tempo: Float = 1) {
    let dt = Float(min(deltaTime, 1.0 / 30.0))
    let k = stiffness * max(0.05, tempo)
    let c = 2 * sqrt(k) * dampingRatio
    velocity += (k * (target - value) - c * velocity) * dt
    value += velocity * dt
  }

  mutating func jump() {
    value = target
    velocity = .zero
  }
}
