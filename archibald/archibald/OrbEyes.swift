import SceneKit
import simd

final class OrbEyes {

  enum Expression {
    case neutral
    case wide  // Excited / listening
    case squint  // Agent speaking
    case drowsy  // Idle for a while
  }

  let leftEyeNode = SCNNode()
  let rightEyeNode = SCNNode()

  private let leftPupilNode = SCNNode()
  private let rightPupilNode = SCNNode()
  private var scleraMaterials: [SCNMaterial] = []
  private var highlightMaterials: [SCNMaterial] = []

  // Saccadic gaze: springs chase the fixation; on a saccade they jump.
  private var gazeSpring = OrbSpring2(value: SIMD2<Float>(0, 0), stiffness: 240, dampingRatio: 1.0)

  // Expression springs (slightly underdamped so pose changes have life).
  private var scleraSpring = OrbSpring(value: 1.0, stiffness: 60, dampingRatio: 0.8)
  private var pupilSpring = OrbSpring(value: 1.0, stiffness: 60, dampingRatio: 0.8)

  private let scleraRadius: CGFloat = 0.092
  private let pupilRadius: CGFloat = 0.046
  static let maxPupilOffset: Float = 0.021
  private let convergence: Float = 0.0045

  private static func eyePosition(
    roughDirection: SIMD3<Float>, parentRadius: Float, outwardInset: Float
  ) -> SCNVector3 {
    let n = simd_normalize(roughDirection)
    let p = n * (parentRadius + outwardInset)
    return SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))
  }

  init(parentRadius: Float) {
    // Slightly less radial protrusion than brows so brows can sit in front and occlude without z-fighting.
    let outward: Float = 0.022
    let leftPos = Self.eyePosition(
      roughDirection: SIMD3<Float>(-0.15, 0.1, parentRadius - 0.04),
      parentRadius: parentRadius,
      outwardInset: outward
    )
    let rightPos = Self.eyePosition(
      roughDirection: SIMD3<Float>(0.15, 0.1, parentRadius - 0.04),
      parentRadius: parentRadius,
      outwardInset: outward
    )
    setupEye(eyeNode: leftEyeNode, pupilNode: leftPupilNode, position: leftPos)
    setupEye(eyeNode: rightEyeNode, pupilNode: rightPupilNode, position: rightPos)
    leftEyeNode.renderingOrder = 0
    rightEyeNode.renderingOrder = 0
  }

  /// - Parameters:
  ///   - gazeTarget: fixation in ±1 pupil-range units.
  ///   - saccade: jump to the fixation this frame instead of springing.
  ///   - blink: 0 open ... 1 closed (blink envelope + sleep lid).
  ///   - lidDroop: 0...1 partial heaviness (drowsiness), independent of blinks.
  ///   - tempo: affect tempo — scales expression spring speed.
  func update(
    deltaTime: TimeInterval,
    gazeTarget: SIMD2<Float>,
    saccade: Bool,
    expression: Expression,
    blink: Float,
    lidDroop: Float,
    tempo: Float
  ) {
    updateGaze(deltaTime: deltaTime, target: gazeTarget, saccade: saccade)
    updateExpression(
      deltaTime: deltaTime, expression: expression, blink: blink, lidDroop: lidDroop, tempo: tempo)
  }

  private func setupEye(eyeNode: SCNNode, pupilNode: SCNNode, position: SCNVector3) {
    eyeNode.position = position

    let sclera = SCNCylinder(radius: scleraRadius, height: 0.015)
    sclera.radialSegmentCount = 32
    let scleraMat = SCNMaterial()
    scleraMat.lightingModel = .constant
    scleraMat.diffuse.contents = NSColor(calibratedWhite: 0.94, alpha: 1.0)
    scleraMat.emission.contents = NSColor(calibratedWhite: 0.22, alpha: 1.0)
    sclera.firstMaterial = scleraMat
    scleraMaterials.append(scleraMat)
    eyeNode.geometry = sclera
    eyeNode.eulerAngles.x = .pi / 2

    let pupil = SCNSphere(radius: pupilRadius)
    pupil.segmentCount = 24
    let pupilMat = SCNMaterial()
    pupilMat.lightingModel = .constant
    pupilMat.diffuse.contents = NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.13, alpha: 1.0)
    pupilMat.emission.contents = NSColor(calibratedWhite: 0.04, alpha: 1.0)
    pupil.firstMaterial = pupilMat
    pupilNode.geometry = pupil
    pupilNode.position = SCNVector3(0, 0.01, 0)
    eyeNode.addChildNode(pupilNode)

    let pupilHighlightGeom = SCNSphere(radius: pupilRadius * 0.2)
    pupilHighlightGeom.segmentCount = 12
    let pupilHighlightMat = SCNMaterial()
    pupilHighlightMat.lightingModel = .constant
    pupilHighlightMat.diffuse.contents = NSColor.white
    pupilHighlightMat.emission.contents = NSColor(calibratedWhite: 0.55, alpha: 1.0)
    pupilHighlightGeom.firstMaterial = pupilHighlightMat
    highlightMaterials.append(pupilHighlightMat)
    let pupilHighlightNode = SCNNode(geometry: pupilHighlightGeom)
    pupilHighlightNode.position = SCNVector3(
      CGFloat(pupilRadius * 0.42),
      CGFloat(pupilRadius * 0.38),
      CGFloat(pupilRadius * 0.72)
    )
    pupilNode.addChildNode(pupilHighlightNode)
  }

  private func updateGaze(deltaTime: TimeInterval, target: SIMD2<Float>, saccade: Bool) {
    gazeSpring.target = SIMD2<Float>(
      max(-1, min(1, target.x)) * Self.maxPupilOffset,
      max(-1, min(1, target.y)) * Self.maxPupilOffset
    )
    if saccade {
      gazeSpring.jump()
    } else {
      gazeSpring.update(deltaTime: deltaTime)
    }

    let gx = gazeSpring.value.x
    let gy = gazeSpring.value.y
    leftPupilNode.position = SCNVector3(CGFloat(gx + convergence), 0.01, CGFloat(-gy))
    rightPupilNode.position = SCNVector3(CGFloat(gx - convergence), 0.01, CGFloat(-gy))
  }

  private func updateExpression(
    deltaTime: TimeInterval, expression: Expression, blink: Float, lidDroop: Float, tempo: Float
  ) {
    switch expression {
    case .neutral:
      scleraSpring.target = 1.0
      pupilSpring.target = 1.0
    case .wide:
      scleraSpring.target = 1.08
      pupilSpring.target = 1.06
    case .squint:
      scleraSpring.target = 0.98
      pupilSpring.target = 0.9
    case .drowsy:
      scleraSpring.target = 0.92
      pupilSpring.target = 0.84
    }

    scleraSpring.update(deltaTime: deltaTime, tempo: tempo)
    pupilSpring.update(deltaTime: deltaTime, tempo: tempo)

    // Eyelid: the eye cylinder is rotated x = π/2, so local Z is screen-vertical.
    // Flattening Z closes the lid; droop is a partial baseline, blink drives to shut.
    let open = max(0.05, (1 - blink) * (1 - lidDroop * 0.55))

    // A closed lid should read as a dark slit, not a glowing white sliver — but only
    // once the lid is genuinely coming down. Partial drowsy droop keeps bright eyes;
    // the darkening ramps in over the last half of closure so open eyes never gray out.
    let shut = 1 - open
    let closure = CGFloat(min(1, max(0, (shut - 0.4) / 0.5)))
    let lidWhite = 0.94 - (0.94 - 0.06) * closure
    for material in scleraMaterials {
      material.diffuse.contents = NSColor(calibratedWhite: lidWhite, alpha: 1.0)
      material.emission.contents = NSColor(calibratedWhite: 0.26 * (1 - closure), alpha: 1.0)
    }
    for material in highlightMaterials {
      material.diffuse.contents = NSColor(calibratedWhite: 1.0 - closure, alpha: 1.0)
      material.emission.contents = NSColor(calibratedWhite: 0.55 * (1 - closure), alpha: 1.0)
    }

    let ss = scleraSpring.value
    leftEyeNode.scale = SCNVector3(CGFloat(ss), CGFloat(ss), CGFloat(ss * open))
    rightEyeNode.scale = SCNVector3(CGFloat(ss), CGFloat(ss), CGFloat(ss * open))

    let ps = pupilSpring.value
    leftPupilNode.scale = SCNVector3(CGFloat(ps), CGFloat(ps), CGFloat(ps))
    rightPupilNode.scale = SCNVector3(CGFloat(ps), CGFloat(ps), CGFloat(ps))
  }
}
