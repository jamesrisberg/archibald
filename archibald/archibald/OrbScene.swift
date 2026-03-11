import AppKit
import SceneKit

final class OrbScene {
  let scene: SCNScene
  private let orbNode = SCNNode()
  private var pulseScale: CGFloat = 1.0
  private var hoverPhase: CGFloat = 0
  private var currentColor = SIMD3<Double>(0.2, 0.95, 0.55)
  private let keyLightNode = SCNNode()
  private let rimLightNode = SCNNode()
  private var currentLightColor = SIMD3<Double>(0.2, 0.95, 0.55)

  // Time-based animation state
  private var previousTime: TimeInterval = 0
  private var previousSpeechState: VoiceSessionManager.SpeechState = .idle
  private var previousListening = false
  private var previousRms: Double = 0

  // Squash & stretch
  private var currentSquashStretch = SIMD3<Float>(1, 1, 1)

  // Eyes
  private let eyes = OrbEyes(parentRadius: 0.6)
  private var idleDuration: TimeInterval = 0

  // Fidgets
  private let fidgetController = OrbFidgetController()

  // Reactions
  private let reactionController = OrbReactionController()

  // Particles
  private var particleSystem: SCNParticleSystem?
  private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  init() {
    scene = SCNScene()
    setupCamera()
    setupLighting()
    setupOrb()
    setupEyes()
    setupParticles()
  }

  func update(
    time: TimeInterval,
    features: VoiceSessionManager.AudioFeatures,
    speechState: VoiceSessionManager.SpeechState,
    isListening: Bool,
    rmsOverride: Double?,
    mousePosition: NSPoint?
  ) {
    let deltaTime = previousTime > 0 ? min(time - previousTime, 1.0 / 15.0) : 1.0 / 60.0
    previousTime = time

    hoverPhase += CGFloat(deltaTime * 3.0)
    let hover = 0.025 * sin(hoverPhase)
    let isSpeaking = speechState != .idle || isListening
    let isUser = speechState == .userSpeaking || isListening
    let activeRms = rmsOverride ?? features.rms
    let multiplier: CGFloat = isUser ? 0.75 : 0.35
    let cap: CGFloat = isUser ? 0.26 : 0.16
    let pulseAmount: CGFloat = isSpeaking ? min(cap, CGFloat(activeRms) * multiplier) : 0.0
    let targetScale: CGFloat = 1.0 + pulseAmount
    pulseScale = lerp(current: pulseScale, target: targetScale, amount: 0.2)
    let combinedScale = pulseScale

    // Squash & stretch: driven by rate of change in audio energy
    let rmsDerivative = deltaTime > 0 ? (activeRms - previousRms) / deltaTime : 0
    let stretchAmount = Float(min(0.08, max(-0.08, rmsDerivative * 0.04)))
    let baseScale = Float(combinedScale)
    let targetScaleY = baseScale + stretchAmount
    let targetScaleXZ = baseScale - stretchAmount * 0.5  // Volume preservation
    let targetSS = SIMD3<Float>(targetScaleXZ, targetScaleY, targetScaleXZ)
    let ssSpeed = Float(deltaTime * 12.0)
    currentSquashStretch += (targetSS - currentSquashStretch) * ssSpeed

    // Idle fidgets
    let isIdle = speechState == .idle && !isListening
    let fidget = fidgetController.update(deltaTime: deltaTime, isIdle: isIdle, currentTime: time)

    orbNode.scale = SCNVector3(
      currentSquashStretch.x,
      currentSquashStretch.y,
      currentSquashStretch.z
    )
    orbNode.position = SCNVector3(
      CGFloat(fidget.positionOffset.x),
      hover + CGFloat(fidget.positionOffset.y),
      CGFloat(fidget.positionOffset.z)
    )
    orbNode.eulerAngles = SCNVector3(
      CGFloat(fidget.rotationOffset.x),
      CGFloat(fidget.rotationOffset.y),
      CGFloat(fidget.rotationOffset.z)
    )

    let targetColor: SIMD3<Double>
    switch speechState {
    case .agentSpeaking:
      targetColor = SIMD3(0.2, 0.55, 1.0)
    case .userSpeaking:
      targetColor = SIMD3(1.0, 0.25, 0.25)
    case .idle:
      targetColor = isListening ? SIMD3(1.0, 0.25, 0.25) : SIMD3(0.2, 0.95, 0.55)
    }

    currentColor = lerp(current: currentColor, target: targetColor, amount: 0.08)
    let baseColor = NSColor(
      calibratedRed: currentColor.x,
      green: currentColor.y,
      blue: currentColor.z,
      alpha: 1.0
    )
    let glowBoost = CGFloat(min(1.0, 0.25 + (features.rms * 1.1)))
    orbNode.geometry?.firstMaterial?.diffuse.contents = baseColor
    orbNode.geometry?.firstMaterial?.emission.contents = baseColor.withAlphaComponent(glowBoost)

    let targetLightColor: SIMD3<Double>
    switch speechState {
    case .userSpeaking:
      targetLightColor = SIMD3(1.0, 0.25, 0.25)
    case .agentSpeaking:
      targetLightColor = SIMD3(0.2, 0.55, 1.0)
    case .idle:
      targetLightColor = isListening ? SIMD3(1.0, 0.25, 0.25) : SIMD3(0.2, 0.95, 0.55)
    }
    currentLightColor = lerp(current: currentLightColor, target: targetLightColor, amount: 0.08)
    let lightColor = NSColor(
      calibratedRed: currentLightColor.x,
      green: currentLightColor.y,
      blue: currentLightColor.z,
      alpha: 1.0
    )
    keyLightNode.light?.color = lightColor
    rimLightNode.light?.color = lightColor

    // Determine eye expression from state
    if isIdle {
      idleDuration += deltaTime
    } else {
      idleDuration = 0
    }

    let eyeExpression: OrbEyes.Expression
    if isListening && !previousListening {
      eyeExpression = .wide
    } else if speechState == .userSpeaking {
      eyeExpression = .wide
    } else if speechState == .agentSpeaking {
      eyeExpression = .squint
    } else if idleDuration > 10.0 {
      eyeExpression = .drowsy
    } else {
      eyeExpression = .neutral
    }

    // Use fidget gaze override if present, otherwise mouse position
    let effectiveMousePosition: NSPoint?
    if let gazeOverride = fidget.eyeGazeOverride {
      effectiveMousePosition = NSPoint(
        x: CGFloat(gazeOverride.x / 0.03),  // Convert back to -1...1 range
        y: CGFloat(gazeOverride.y / 0.03)
      )
    } else {
      effectiveMousePosition = mousePosition
    }

    eyes.update(
      deltaTime: deltaTime, mousePosition: effectiveMousePosition, expression: eyeExpression)
    eyes.updateLidColor(baseColor)

    // Detect state transitions and trigger reactions
    if speechState != previousSpeechState {
      switch (previousSpeechState, speechState) {
      case (_, .userSpeaking):
        reactionController.trigger(.userStartedSpeaking, at: time)
      case (_, .agentSpeaking):
        reactionController.trigger(.agentStartedSpeaking, at: time)
      case (.userSpeaking, .idle), (.agentSpeaking, .idle):
        if !isListening {
          reactionController.trigger(.conversationEnded, at: time)
        }
      default:
        break
      }
    }
    if isListening && !previousListening {
      reactionController.trigger(.summoned, at: time)
    }

    // Apply reaction outputs (additive to fidget)
    let reaction = reactionController.update(currentTime: time)
    if reactionController.isActive {
      orbNode.position.y += CGFloat(reaction.positionOffset.y)
      orbNode.eulerAngles.x += CGFloat(reaction.rotationOffset.x)
      orbNode.scale.x *= CGFloat(reaction.scaleMultiplier)
      orbNode.scale.y *= CGFloat(reaction.scaleMultiplier)
      orbNode.scale.z *= CGFloat(reaction.scaleMultiplier)
    }

    // Modulate particles
    if let ps = particleSystem {
      let targetBirthRate: CGFloat
      switch speechState {
      case .userSpeaking: targetBirthRate = 8
      case .agentSpeaking: targetBirthRate = 12
      case .idle: targetBirthRate = isListening ? 5 : 2
      }
      ps.birthRate = targetBirthRate
      ps.particleColor = baseColor.withAlphaComponent(0.7)
    }

    // Track state for transition detection
    let activeRmsForTracking = rmsOverride ?? features.rms
    previousSpeechState = speechState
    previousListening = isListening
    previousRms = activeRmsForTracking
  }

  func triggerDismissed() {
    reactionController.trigger(.dismissed, at: previousTime)
  }

  func loadModel(from url: URL) {
    // TODO: Replace placeholder geometry with a real USDZ model and blendshapes.
    _ = url
  }

  private func setupCamera() {
    let camera = SCNCamera()
    camera.zNear = 0.1
    camera.zFar = 100
    let node = SCNNode()
    node.camera = camera
    node.position = SCNVector3(0, 0.1, 2.3)
    scene.rootNode.addChildNode(node)
  }

  private func setupLighting() {
    let light = SCNLight()
    light.type = .omni
    light.intensity = 260
    light.color = NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.55, alpha: 1.0)
    keyLightNode.light = light
    keyLightNode.position = SCNVector3(1.6, 1.2, 2.2)
    scene.rootNode.addChildNode(keyLightNode)

    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 55
    ambient.color = NSColor(calibratedWhite: 0.2, alpha: 1.0)
    let ambientNode = SCNNode()
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)

    let rim = SCNLight()
    rim.type = .directional
    rim.intensity = 120
    rim.color = NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.55, alpha: 1.0)
    rimLightNode.light = rim
    rimLightNode.eulerAngles = SCNVector3(-0.4, 0.8, 0)
    scene.rootNode.addChildNode(rimLightNode)
  }

  private func setupOrb() {
    let orb = SCNSphere(radius: 0.6)
    orb.segmentCount = 96
    let material = orb.firstMaterial ?? SCNMaterial()
    material.lightingModel = .physicallyBased
    material.diffuse.contents = NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.55, alpha: 1.0)
    material.emission.contents = NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.55, alpha: 0.25)
    material.metalness.contents = 0.35
    material.roughness.contents = 0.06
    material.specular.contents = NSColor.white
    material.specular.intensity = 1.2
    material.transparency = 1.0
    orb.firstMaterial = material
    orbNode.geometry = orb
    scene.rootNode.addChildNode(orbNode)
  }

  private func setupEyes() {
    orbNode.addChildNode(eyes.leftEyeNode)
    orbNode.addChildNode(eyes.rightEyeNode)
  }

  private func setupParticles() {
    guard !reduceMotion else { return }

    let particles = SCNParticleSystem()
    particles.emitterShape = SCNSphere(radius: 0.65)
    particles.emittingDirection = SCNVector3(0, 1, 0)
    particles.spreadingAngle = 180
    particles.birthRate = 2
    particles.particleLifeSpan = 4.0
    particles.particleLifeSpanVariation = 1.5
    particles.particleSize = 0.012
    particles.particleSizeVariation = 0.006
    particles.particleVelocity = 0.02
    particles.particleVelocityVariation = 0.01
    particles.particleColor = NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.55, alpha: 0.7)
    particles.particleColorVariation = SCNVector4(0.1, 0.1, 0.1, 0.2)
    particles.blendMode = .additive
    particles.isAffectedByGravity = false
    particles.isAffectedByPhysicsFields = false

    // Fade in and out over particle lifetime
    let sizeAnim = CAKeyframeAnimation()
    sizeAnim.values = [0.0, 1.0, 1.0, 0.0] as [NSNumber]
    sizeAnim.keyTimes = [0.0, 0.1, 0.8, 1.0]
    sizeAnim.duration = 1.0
    let sizeController = SCNParticlePropertyController(animation: sizeAnim)
    particles.propertyControllers = [.size: sizeController]

    particleSystem = particles
    orbNode.addParticleSystem(particles)
  }

  private func lerp(current: CGFloat, target: CGFloat, amount: CGFloat) -> CGFloat {
    current + (target - current) * amount
  }

  private func lerp(current: SIMD3<Double>, target: SIMD3<Double>, amount: Double) -> SIMD3<Double>
  {
    current + (target - current) * amount
  }
}
