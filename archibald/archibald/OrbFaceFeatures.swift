import AppKit
import SceneKit
import simd

/// Thick black brows: expression poses + idle motion that moves **in tandem** (shared phase) with
/// small **coupled** left/right splits so they’re not identical but feel like one muscle pair.
final class OrbFaceFeatures {

  let leftBrowNode = SCNNode()
  let rightBrowNode = SCNNode()

  private let parentRadius: Float
  private let outward: Float

  private let browPitchX: Float = Float.pi * 0.1
  private var smileCurvatureSmoothed: CGFloat = 0

  private static func radialPosition(
    roughDirection: SIMD3<Float>, parentRadius: Float, outwardInset: Float
  ) -> SCNVector3 {
    let n = simd_normalize(roughDirection)
    let p = n * (parentRadius + outwardInset)
    return SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))
  }

  init(parentRadius: Float, outwardInset: Float = 0.028) {
    self.parentRadius = parentRadius
    self.outward = outwardInset
    setupBrows()
    applyBlackBrows()
  }

  /// - Parameters:
  ///   - rms/zcr: smoothed output-audio features; drive the brows while the agent talks.
  ///   - sadness: 0...1 from negative valence — inner corners up, overall droop.
  ///   - thinking: 0...1 — brow knit while pondering.
  ///   - energy: affect arousal; scales idle wander amplitude.
  func update(
    deltaTime: TimeInterval,
    time: TimeInterval,
    speechState: VoiceSessionManager.SpeechState,
    isListening: Bool,
    eyeExpression: OrbEyes.Expression,
    rms: CGFloat,
    zcr: CGFloat,
    sadness: CGFloat,
    thinking: CGFloat,
    energy: CGFloat
  ) {
    let dt = CGFloat(min(deltaTime, 1.0 / 30.0))
    let isIdle = speechState == .idle && !isListening
    let idleAmp: CGFloat = (isIdle ? 1.0 : 0.38) * (0.45 + 0.75 * energy)

    // --- Expression: exaggerated base poses + intentional asymmetry
    var lift: CGFloat = 0.018
    var leftZ: CGFloat = -0.1
    var rightZ: CGFloat = 0.1
    var liftAsymL: CGFloat = 0.004
    var liftAsymR: CGFloat = -0.004
    var zAsymL: CGFloat = 0.02
    var zAsymR: CGFloat = -0.02

    switch eyeExpression {
    case .wide:
      lift = 0.042
      leftZ = -0.2
      rightZ = 0.2
      liftAsymL = 0.014
      liftAsymR = -0.006
      zAsymL = 0.05
      zAsymR = -0.03
    case .squint:
      lift = -0.012
      leftZ = -0.04
      rightZ = 0.04
      liftAsymL = -0.006
      liftAsymR = 0.003
      zAsymL = -0.06
      zAsymR = 0.05
    case .drowsy:
      lift = -0.022
      leftZ = 0.03
      rightZ = -0.03
      liftAsymL = -0.01
      liftAsymR = 0.002
      zAsymL = -0.02
      zAsymR = 0.02
    case .neutral:
      lift = 0.018
      leftZ = -0.1
      rightZ = 0.1
      liftAsymL = 0.004
      liftAsymR = -0.004
      zAsymL = 0.02
      zAsymR = -0.02
    }

    // Speech overlays (brows do the talking — no mouth)
    switch speechState {
    case .userSpeaking:
      lift += 0.01
      leftZ -= 0.03
      rightZ += 0.03
    case .agentSpeaking:
      // Audio-driven: loudness lifts the brows, sibilance flutters them.
      lift -= 0.008
      leftZ += 0.025
      rightZ -= 0.025
      lift += rms * 0.035
      let flutter = sin(time * 13.0) * zcr * 0.05
      leftZ -= flutter
      rightZ += flutter
    case .thinking:
      break  // Handled by the knit pose below.
    case .idle:
      break
    }
    if isListening {
      lift += 0.014
      leftZ -= 0.06
      rightZ += 0.06
    }

    // Thinking knit: inner ends pinch up-and-in while pondering.
    lift -= 0.005 * thinking
    leftZ += 0.11 * thinking
    rightZ -= 0.11 * thinking

    // Sadness (negative valence): same family as drowsy but heavier — inner up, body down.
    lift -= 0.008 * sadness
    leftZ += 0.14 * sadness
    rightZ -= 0.14 * sadness

    let engaged = CGFloat(isIdle ? 1.0 : 0.65)
    smileCurvatureSmoothed += (engaged - smileCurvatureSmoothed) * dt * 5.0
    let curve = 0.55 + 0.45 * smileCurvatureSmoothed

    // --- Idle: shared “bundle” motion (both brows move together) + small split (not identical)
    // Same underlying phase `p` so it never feels like two random LFOs.
    let p = time * 0.85
    let bundleLift =
      sin(p * 0.37 + 0.12) * 0.012 + sin(p * 0.11 + 0.4) * 0.0045
    let splitLift = sin(p * 0.41 + 0.65) * 0.0065
    let bundleTilt =
      sin(p * 0.35 + 0.22) * 0.058 + sin(p * 0.13 + 0.05) * 0.02
    let splitTilt = sin(p * 0.33 + 0.95) * 0.028

    let leftLiftWave = bundleLift + splitLift
    let rightLiftWave = bundleLift - splitLift
    let leftTiltWave = bundleTilt + splitTilt
    let rightTiltWave = bundleTilt - splitTilt

    let baseLeft = Self.browBaseLeft(parentRadius: parentRadius, outward: outward)
    let baseRight = Self.browBaseRight(parentRadius: parentRadius, outward: outward)

    leftBrowNode.position = SCNVector3(
      baseLeft.x,
      baseLeft.y + lift + liftAsymL + CGFloat(leftLiftWave) * idleAmp,
      baseLeft.z
    )
    rightBrowNode.position = SCNVector3(
      baseRight.x,
      baseRight.y + lift + liftAsymR + CGFloat(rightLiftWave) * idleAmp,
      baseRight.z
    )

    let lz = (leftZ + zAsymL + leftTiltWave * idleAmp) * curve
    let rz = (rightZ + zAsymR + rightTiltWave * idleAmp) * curve
    leftBrowNode.eulerAngles = SCNVector3(browPitchX, 0, Float(lz))
    rightBrowNode.eulerAngles = SCNVector3(browPitchX, 0, Float(rz))
  }

  /// Thick black — no orb tint (reads reliably).
  func applyBlackBrows() {
    for geo in [leftBrowNode.geometry, rightBrowNode.geometry].compactMap({ $0 }) {
      let materials: [SCNMaterial] = geo.materials.isEmpty
        ? [geo.firstMaterial].compactMap { $0 }
        : geo.materials
      for m in materials {
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.emission.contents = NSColor(white: 0.07, alpha: 1.0)
      }
    }
  }

  // MARK: - Setup

  /// Extra radial offset so brows sit clearly in front of the sclera at rest; when animation
  /// brings them down over the eyes, renderingOrder lets them win depth ties.
  private static func browOutwardExtra(parentRadius: Float) -> Float {
    max(0.092, parentRadius * 0.16)
  }

  private static func browBaseLeft(parentRadius: Float, outward: Float) -> SCNVector3 {
    radialPosition(
      roughDirection: SIMD3<Float>(-0.15, 0.2, parentRadius - 0.04),
      parentRadius: parentRadius,
      outwardInset: outward + browOutwardExtra(parentRadius: parentRadius)
    )
  }

  private static func browBaseRight(parentRadius: Float, outward: Float) -> SCNVector3 {
    radialPosition(
      roughDirection: SIMD3<Float>(0.15, 0.2, parentRadius - 0.04),
      parentRadius: parentRadius,
      outwardInset: outward + browOutwardExtra(parentRadius: parentRadius)
    )
  }

  /// Asymmetric lens: bulge peaks toward +x (inner / nose on the left brow; mirrored for right).
  /// Outer tip (-w) stays thinner than inner (+w). Short span + deep extrusion = chunky stroke.
  private static func makeBrowPath() -> NSBezierPath {
    let w: CGFloat = 0.076
    let hOuter: CGFloat = 0.125
    let hInner: CGFloat = 0.003
    let innerShift = 0.34 * w
    let p = NSBezierPath()
    p.move(to: CGPoint(x: -w, y: 0))
    p.curve(to: CGPoint(x: w, y: 0), controlPoint: CGPoint(x: innerShift, y: hOuter))
    p.curve(to: CGPoint(x: -w, y: 0), controlPoint: CGPoint(x: innerShift * 0.72, y: hInner))
    p.close()
    return p
  }

  private func setupBrows() {
    let leftPath = Self.makeBrowPath()
    let rightPath = (leftPath.copy() as! NSBezierPath)
    var flip = AffineTransform.identity
    flip.scale(x: -1, y: 1)
    rightPath.transform(using: flip)

    let mat = SCNMaterial()
    mat.lightingModel = .constant
    mat.diffuse.contents = NSColor.black
    mat.emission.contents = NSColor(white: 0.07, alpha: 1.0)
    mat.isDoubleSided = true
    mat.readsFromDepthBuffer = true
    mat.writesToDepthBuffer = true

    // ~3× prior depth so the stroke reads chunky head-on, not a ribbon
    let depth: CGFloat = 0.168
    let leftGeom = SCNShape(path: leftPath, extrusionDepth: depth)
    let rightGeom = SCNShape(path: rightPath, extrusionDepth: depth)
    leftGeom.materials = [mat]
    rightGeom.materials = [mat]

    leftBrowNode.geometry = leftGeom
    rightBrowNode.geometry = rightGeom
    leftBrowNode.position = Self.browBaseLeft(parentRadius: parentRadius, outward: outward)
    rightBrowNode.position = Self.browBaseRight(parentRadius: parentRadius, outward: outward)
    leftBrowNode.renderingOrder = 100
    rightBrowNode.renderingOrder = 100

    leftBrowNode.eulerAngles = SCNVector3(browPitchX, 0, -0.1)
    rightBrowNode.eulerAngles = SCNVector3(browPitchX, 0, 0.1)
    leftBrowNode.scale = SCNVector3(1, 1, 1)
    rightBrowNode.scale = SCNVector3(1, 1, 1)
  }
}
