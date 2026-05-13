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

  // Gaze state
  private var currentGaze = SIMD2<Float>(0, 0)

  // Expression state
  private var currentScleraScale: CGFloat = 1.0
  private var targetScleraScale: CGFloat = 1.0
  private var currentPupilScale: CGFloat = 1.0
  private var targetPupilScale: CGFloat = 1.0

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

  func update(deltaTime: TimeInterval, mousePosition: NSPoint?, expression: Expression) {
    updateGaze(deltaTime: deltaTime, mousePosition: mousePosition, expression: expression)
    updateExpression(deltaTime: deltaTime, expression: expression)
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
    let pupilHighlightNode = SCNNode(geometry: pupilHighlightGeom)
    pupilHighlightNode.position = SCNVector3(
      CGFloat(pupilRadius * 0.42),
      CGFloat(pupilRadius * 0.38),
      CGFloat(pupilRadius * 0.72)
    )
    pupilNode.addChildNode(pupilHighlightNode)
  }

  private func updateGaze(
    deltaTime: TimeInterval, mousePosition: NSPoint?, expression: Expression
  ) {
    var gazeTarget = SIMD2<Float>(0, 0)

    if let mouse = mousePosition {
      gazeTarget = SIMD2<Float>(
        Float(clamp(mouse.x, min: -1, max: 1)) * Self.maxPupilOffset,
        Float(clamp(mouse.y, min: -1, max: 1)) * Self.maxPupilOffset
      )
    }

    if expression == .wide {
      gazeTarget.y += Self.maxPupilOffset * 0.12
    }

    let gazeDt = min(Float(deltaTime), 1.0 / 45.0)
    let lerpSpeed = gazeDt * 8.2
    currentGaze.x += (gazeTarget.x - currentGaze.x) * lerpSpeed
    currentGaze.y += (gazeTarget.y - currentGaze.y) * lerpSpeed

    let gx = currentGaze.x
    let gy = currentGaze.y
    leftPupilNode.position = SCNVector3(CGFloat(gx + convergence), 0.01, CGFloat(-gy))
    rightPupilNode.position = SCNVector3(CGFloat(gx - convergence), 0.01, CGFloat(-gy))
  }

  private func updateExpression(deltaTime: TimeInterval, expression: Expression) {
    switch expression {
    case .neutral:
      targetScleraScale = 1.0
      targetPupilScale = 1.0
    case .wide:
      targetScleraScale = 1.08
      targetPupilScale = 1.06
    case .squint:
      targetScleraScale = 0.98
      targetPupilScale = 0.9
    case .drowsy:
      targetScleraScale = 0.92
      targetPupilScale = 0.84
    }

    let speed = CGFloat(deltaTime * 5.0)
    currentScleraScale += (targetScleraScale - currentScleraScale) * speed
    currentPupilScale += (targetPupilScale - currentPupilScale) * speed

    let ss = Float(currentScleraScale)
    leftEyeNode.scale = SCNVector3(ss, ss, ss)
    rightEyeNode.scale = SCNVector3(ss, ss, ss)

    let ps = Float(currentPupilScale)
    leftPupilNode.scale = SCNVector3(ps, ps, ps)
    rightPupilNode.scale = SCNVector3(ps, ps, ps)
  }

  private func clamp(_ value: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) -> CGFloat {
    Swift.min(maxVal, Swift.max(minVal, value))
  }
}
