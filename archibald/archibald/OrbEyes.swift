import SceneKit

final class OrbEyes {

  enum Expression {
    case neutral
    case wide      // Excited / listening
    case squint    // Agent speaking
    case drowsy    // Idle for a while
  }

  let leftEyeNode = SCNNode()
  let rightEyeNode = SCNNode()

  private let leftPupilNode = SCNNode()
  private let rightPupilNode = SCNNode()
  private let leftLidNode = SCNNode()
  private let rightLidNode = SCNNode()

  // Blink state
  private var blinkTimer: TimeInterval = 0
  private var nextBlinkAt: TimeInterval = Double.random(in: 2.0...5.0)
  private var blinkPhase: CGFloat = 0       // 0 = open, 1 = closed
  private var blinkDirection: CGFloat = 0   // 1 = closing, -1 = opening, 0 = idle
  private var pendingDoubleBlink = false

  // Gaze state
  private var currentGaze = SIMD2<Float>(0, 0)

  // Expression state
  private var currentLidClose: CGFloat = 0       // 0 = open, 1 = fully closed
  private var targetLidClose: CGFloat = 0
  private var currentScleraScale: CGFloat = 1.0
  private var targetScleraScale: CGFloat = 1.0
  private var currentPupilScale: CGFloat = 1.0
  private var targetPupilScale: CGFloat = 1.0

  // Geometry sizes
  private let scleraRadius: CGFloat = 0.1
  private let pupilRadius: CGFloat = 0.045
  private let lidHeight: CGFloat = 0.22
  private let maxPupilOffset: Float = 0.03

  init(parentRadius: Float) {
    setupEye(
      eyeNode: leftEyeNode,
      pupilNode: leftPupilNode,
      lidNode: leftLidNode,
      position: SCNVector3(-0.15, 0.1, CGFloat(parentRadius) - 0.04)
    )
    setupEye(
      eyeNode: rightEyeNode,
      pupilNode: rightPupilNode,
      lidNode: rightLidNode,
      position: SCNVector3(0.15, 0.1, CGFloat(parentRadius) - 0.04)
    )
  }

  func update(deltaTime: TimeInterval, mousePosition: NSPoint?, expression: Expression) {
    updateBlink(deltaTime: deltaTime)
    updateGaze(deltaTime: deltaTime, mousePosition: mousePosition, expression: expression)
    updateExpression(deltaTime: deltaTime, expression: expression)
    applyLidState()
  }

  // MARK: - Setup

  private func setupEye(
    eyeNode: SCNNode, pupilNode: SCNNode, lidNode: SCNNode, position: SCNVector3
  ) {
    eyeNode.position = position

    // Sclera — flat white disc facing forward
    let sclera = SCNCylinder(radius: scleraRadius, height: 0.015)
    sclera.radialSegmentCount = 32
    let scleraMat = SCNMaterial()
    scleraMat.lightingModel = .constant
    scleraMat.diffuse.contents = NSColor.white
    scleraMat.emission.contents = NSColor(white: 0.9, alpha: 1.0)
    sclera.firstMaterial = scleraMat
    eyeNode.geometry = sclera
    // Rotate so the flat face points toward camera (+Z)
    eyeNode.eulerAngles.x = .pi / 2

    // Pupil — small dark sphere in front of sclera
    let pupil = SCNSphere(radius: pupilRadius)
    pupil.segmentCount = 24
    let pupilMat = SCNMaterial()
    pupilMat.lightingModel = .constant
    pupilMat.diffuse.contents = NSColor(white: 0.05, alpha: 1.0)
    pupilMat.emission.contents = NSColor(white: 0.02, alpha: 1.0)
    pupil.firstMaterial = pupilMat
    pupilNode.geometry = pupil
    // Position slightly in front of sclera disc (in eye-local space, Y is forward because of rotation)
    pupilNode.position = SCNVector3(0, 0.01, 0)
    eyeNode.addChildNode(pupilNode)

    // Eyelid — a plane that slides down to cover the eye
    let lidGeom = SCNPlane(width: scleraRadius * 2.2, height: lidHeight)
    let lidMat = SCNMaterial()
    lidMat.lightingModel = .constant
    lidMat.diffuse.contents = NSColor(calibratedRed: 0.15, green: 0.7, blue: 0.4, alpha: 1.0)
    lidMat.isDoubleSided = true
    lidGeom.firstMaterial = lidMat
    lidNode.geometry = lidGeom
    // Position above the eye; in eye-local rotated space, Z is up
    lidNode.position = SCNVector3(0, 0.012, CGFloat(lidHeight / 2 + scleraRadius * 0.05))
    // The lid is hidden when fully "open" — we'll animate by lowering it
    eyeNode.addChildNode(lidNode)
  }

  // MARK: - Blink

  private func updateBlink(deltaTime: TimeInterval) {
    blinkTimer += deltaTime

    // Trigger new blink when timer expires
    if blinkDirection == 0 && blinkTimer >= nextBlinkAt {
      blinkDirection = 1  // Start closing
    }

    // Animate blink
    if blinkDirection != 0 {
      let blinkSpeed: CGFloat = 12.0  // Full close/open in ~0.08s
      blinkPhase += blinkDirection * CGFloat(deltaTime) * blinkSpeed

      if blinkPhase >= 1.0 {
        blinkPhase = 1.0
        blinkDirection = -1  // Start opening
      }

      if blinkPhase <= 0.0 {
        blinkPhase = 0.0
        blinkDirection = 0  // Done

        if pendingDoubleBlink {
          pendingDoubleBlink = false
          // Trigger second blink shortly
          blinkTimer = nextBlinkAt - 0.15
        } else {
          // Schedule next blink
          blinkTimer = 0
          nextBlinkAt = Double.random(in: 3.0...7.0)
          // 15% chance of double-blink
          if Double.random(in: 0...1) < 0.15 {
            pendingDoubleBlink = true
          }
        }
      }
    }
  }

  // MARK: - Gaze

  private func updateGaze(
    deltaTime: TimeInterval, mousePosition: NSPoint?, expression: Expression
  ) {
    var gazeTarget = SIMD2<Float>(0, 0)

    if let mouse = mousePosition {
      gazeTarget = SIMD2<Float>(
        Float(clamp(mouse.x, min: -1, max: 1)) * maxPupilOffset,
        Float(clamp(mouse.y, min: -1, max: 1)) * maxPupilOffset
      )
    }

    // Expression-based gaze bias
    if expression == .wide {
      gazeTarget.y += maxPupilOffset * 0.3  // Look slightly up when attentive
    }

    let lerpSpeed = Float(deltaTime * 8.0)
    currentGaze.x += (gazeTarget.x - currentGaze.x) * lerpSpeed
    currentGaze.y += (gazeTarget.y - currentGaze.y) * lerpSpeed

    // In eye-local space (rotated 90 degrees around X), X is still left/right, Z is up/down
    leftPupilNode.position = SCNVector3(CGFloat(currentGaze.x), 0.01, CGFloat(-currentGaze.y))
    rightPupilNode.position = SCNVector3(CGFloat(currentGaze.x), 0.01, CGFloat(-currentGaze.y))
  }

  // MARK: - Expression

  private func updateExpression(deltaTime: TimeInterval, expression: Expression) {
    switch expression {
    case .neutral:
      targetLidClose = 0
      targetScleraScale = 1.0
      targetPupilScale = 1.0
    case .wide:
      targetLidClose = 0
      targetScleraScale = 1.15
      targetPupilScale = 1.1
    case .squint:
      targetLidClose = 0.3
      targetScleraScale = 1.0
      targetPupilScale = 0.95
    case .drowsy:
      targetLidClose = 0.5
      targetScleraScale = 0.95
      targetPupilScale = 0.9
    }

    let speed = CGFloat(deltaTime * 5.0)
    currentLidClose += (targetLidClose - currentLidClose) * speed
    currentScleraScale += (targetScleraScale - currentScleraScale) * speed
    currentPupilScale += (targetPupilScale - currentPupilScale) * speed

    // Apply sclera/pupil scale
    let ss = Float(currentScleraScale)
    leftEyeNode.scale = SCNVector3(ss, ss, ss)
    rightEyeNode.scale = SCNVector3(ss, ss, ss)

    let ps = Float(currentPupilScale)
    leftPupilNode.scale = SCNVector3(ps, ps, ps)
    rightPupilNode.scale = SCNVector3(ps, ps, ps)
  }

  // MARK: - Lid

  private func applyLidState() {
    // Combine blink and expression lid closure
    let totalLidClose = min(1.0, blinkPhase + currentLidClose)

    // Lid slides down from above the eye. At totalLidClose=0, lid is above and hidden.
    // At totalLidClose=1, lid fully covers the eye.
    let openOffset = lidHeight / 2 + scleraRadius * 0.05
    let closedOffset: CGFloat = 0
    let lidZ = openOffset - totalLidClose * (openOffset - closedOffset)

    leftLidNode.position.z = lidZ
    rightLidNode.position.z = lidZ
  }

  /// Update the eyelid color to match the current orb color.
  func updateLidColor(_ color: NSColor) {
    leftLidNode.geometry?.firstMaterial?.diffuse.contents = color
    rightLidNode.geometry?.firstMaterial?.diffuse.contents = color
  }

  // MARK: - Helpers

  private func clamp(_ value: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) -> CGFloat {
    Swift.min(maxVal, Swift.max(minVal, value))
  }
}
