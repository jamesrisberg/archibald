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
  private var previousConnectionFailed = false
  /// Smoothed RMS for squash/pulse — raw audio jumps cause visible stutter on the derivative.
  private var smoothedRms: Double = 0
  private var lastSmoothedRms: Double = 0
  private var rmsFilterInitialized = false

  // Squash & stretch
  private var currentSquashStretch = SIMD3<Float>(1, 1, 1)

  // Eyes + simple face (brows, faux mouth)
  private let eyes = OrbEyes(parentRadius: 0.6)
  private let face = OrbFaceFeatures(parentRadius: 0.6)
  private var idleDuration: TimeInterval = 0

  // Emotional spine + involuntary signals
  private let affect = OrbAffect()
  private let blinkController = OrbBlinkController()
  private let gazeController = OrbGazeController()
  private var previousExpression: OrbEyes.Expression = .neutral
  private var thinkingAmount: CGFloat = 0
  /// Attention budget: how busy the user seems (mouse velocity proxy). High → sit still.
  private var busyMeter: Float = 0
  private var lastMouseForVelocity: NSPoint?

  // Fidgets
  private let fidgetController = OrbFidgetController()

  // Reactions
  private let reactionController = OrbReactionController()

  /// Added to eulerAngles.y (slide-in faces edge, slide-out faces edge; at rest ~0).
  var walkFacingYawRadians: CGFloat = 0

  // Particles
  private var particleSystem: SCNParticleSystem?
  private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  init() {
    scene = SCNScene()
    setupCamera()
    setupLighting()
    setupOrb()
    setupFace()
    setupParticles()
  }

  /// Conversation-tone score (-1...1) from sentiment analysis; tints the mood.
  func setSentiment(_ score: Float) {
    affect.setSentiment(score)
  }

  func update(
    time: TimeInterval,
    features: VoiceSessionManager.AudioFeatures,
    speechState: VoiceSessionManager.SpeechState,
    isListening: Bool,
    isConnectionFailed: Bool,
    rmsOverride: Double?,
    mousePosition: NSPoint?
  ) {
    // Cap dt tighter than 1/15s — large steps made squash / hover / fidgets visibly jump.
    let rawDt = previousTime > 0 ? time - previousTime : 1.0 / 60.0
    let deltaTime = min(max(rawDt, 1.0 / 240.0), 1.0 / 40.0)
    previousTime = time

    let activeRms = rmsOverride ?? features.rms

    if !rmsFilterInitialized {
      smoothedRms = activeRms
      lastSmoothedRms = activeRms
      rmsFilterInitialized = true
    } else {
      smoothedRms += (activeRms - smoothedRms) * min(1.0, deltaTime * 22.0)
    }

    let isIdle = speechState == .idle && !isListening
    if isIdle {
      idleDuration += deltaTime
    } else {
      idleDuration = 0
    }

    // --- Emotional spine
    if speechState != previousSpeechState {
      switch speechState {
      case .userSpeaking: affect.apply(event: .userSpoke)
      case .agentSpeaking: affect.apply(event: .agentSpoke)
      case .thinking: affect.apply(event: .thinkingStarted)
      case .idle: break
      }
    }
    if isListening && !previousListening {
      affect.apply(event: .summoned)
    }
    if isConnectionFailed && !previousConnectionFailed {
      affect.apply(event: .connectionLost)
      reactionController.trigger(.connectionLost, at: time)
    }
    affect.update(
      deltaTime: deltaTime,
      speechState: speechState,
      isListening: isListening,
      isConnectionFailed: isConnectionFailed,
      idleTime: idleDuration
    )

    // Attention budget: fast cursor movement = user is working; don't perform.
    if let mouse = mousePosition, let last = lastMouseForVelocity {
      let speed = Float(hypot(mouse.x - last.x, mouse.y - last.y)) / Float(deltaTime)
      let busyTarget: Float = min(1, speed / 5.0)
      let rate: Float = busyTarget > busyMeter ? 4.0 : 0.5
      busyMeter += (busyTarget - busyMeter) * min(1, Float(deltaTime) * rate)
    }
    lastMouseForVelocity = mousePosition

    // --- Breathing hover: two detuned sines, rate/depth from arousal.
    hoverPhase += CGFloat(deltaTime) * CGFloat(affect.breathRate)
    let breath = sin(hoverPhase) + 0.35 * sin(hoverPhase * 1.7 + 1.3)
    let hover = CGFloat(affect.breathDepth) * breath

    let isSpeaking = speechState == .userSpeaking || speechState == .agentSpeaking || isListening
    let isUser = speechState == .userSpeaking || isListening
    let multiplier: CGFloat = isUser ? 0.75 : 0.35
    let cap: CGFloat = isUser ? 0.26 : 0.16
    let pulseAmount: CGFloat = isSpeaking ? min(cap, CGFloat(smoothedRms) * multiplier) : 0.0
    let targetScale: CGFloat = 1.0 + pulseAmount
    let pulseLerp = CGFloat(min(1.0, deltaTime * 12.0))
    pulseScale = lerp(current: pulseScale, target: targetScale, amount: pulseLerp)
    let combinedScale = pulseScale

    // Squash & stretch from smoothed RMS slope (raw RMS spikes were causing stretch pops)
    let rawDerivative =
      deltaTime > 1e-6 ? (smoothedRms - lastSmoothedRms) / deltaTime : 0
    lastSmoothedRms = smoothedRms
    let rmsDerivative = max(-32.0, min(32.0, rawDerivative))
    let stretchAmount = Float(min(0.08, max(-0.08, rmsDerivative * 0.04)))
    let baseScale = Float(combinedScale)
    let targetScaleY = baseScale + stretchAmount
    let targetScaleXZ = baseScale - stretchAmount * 0.5  // Volume preservation
    let targetSS = SIMD3<Float>(targetScaleXZ, targetScaleY, targetScaleXZ)
    let ssSpeed = Float(deltaTime * 12.0)
    currentSquashStretch += (targetSS - currentSquashStretch) * ssSpeed

    // Idle fidgets — energy from affect, suppressed while the user is busy.
    let fidget = fidgetController.update(
      deltaTime: deltaTime,
      isIdle: isIdle,
      currentTime: time,
      energy: affect.fidgetEnergy,
      suppression: busyMeter,
      reduceMotion: reduceMotion
    )

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
    let walkYaw = walkFacingYawRadians
    orbNode.eulerAngles = SCNVector3(
      CGFloat(fidget.rotationOffset.x),
      CGFloat(fidget.rotationOffset.y) + walkYaw,
      CGFloat(fidget.rotationOffset.z)
    )

    // --- Reactions (before the face, so their expression override lands this frame)
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

    let reaction = reactionController.update(currentTime: time)
    if reactionController.isActive {
      orbNode.position.y += CGFloat(reaction.positionOffset.y)
      orbNode.eulerAngles.x += CGFloat(reaction.rotationOffset.x)
      orbNode.eulerAngles.y += CGFloat(reaction.rotationOffset.y)
      orbNode.eulerAngles.z += CGFloat(reaction.rotationOffset.z)
      orbNode.scale.x *= CGFloat(reaction.scaleMultiplier)
      orbNode.scale.y *= CGFloat(reaction.scaleMultiplier)
      orbNode.scale.z *= CGFloat(reaction.scaleMultiplier)
    }

    // --- Expression: latched to state (not edge-triggered); reactions may override.
    let stateExpression: OrbEyes.Expression
    if affect.isAsleep {
      stateExpression = .drowsy
    } else if isListening || speechState == .userSpeaking {
      stateExpression = .wide
    } else if speechState == .agentSpeaking {
      stateExpression = .squint
    } else if speechState == .thinking {
      stateExpression = .neutral  // The thoughtful gaze does the acting.
    } else if affect.lidDroop > 0.3 {
      stateExpression = .drowsy
    } else {
      stateExpression = .neutral
    }
    let eyeExpression = reaction.eyeExpression ?? stateExpression
    if eyeExpression != previousExpression {
      blinkController.requestBlink()  // Natural blink on expression changes.
      previousExpression = eyeExpression
    }

    // --- Gaze: etiquette controller unless a fidget wants the eyes.
    let gazeMode: OrbGazeController.Mode
    if affect.isAsleep {
      gazeMode = .sleepy
    } else if isListening || speechState == .userSpeaking {
      gazeMode = .attentive
    } else if speechState == .agentSpeaking {
      gazeMode = .conversational
    } else if speechState == .thinking {
      gazeMode = .thoughtful
    } else {
      gazeMode = .idle
    }

    let cursor: SIMD2<Float>? = mousePosition.map {
      SIMD2<Float>(Float($0.x), Float($0.y))
    }
    var gazeFrame = gazeController.update(
      deltaTime: deltaTime, mode: gazeMode, cursor: cursor, arousal: affect.arousal)
    if let gazeOverride = fidget.eyeGazeOverride {
      let s = OrbEyes.maxPupilOffset
      gazeFrame.target = SIMD2<Float>(gazeOverride.x / s, gazeOverride.y / s)
      gazeFrame.saccade = false
    }
    if gazeFrame.saccade {
      blinkController.requestBlink()
    }

    let blink = blinkController.update(
      deltaTime: deltaTime, arousal: affect.arousal, isAsleep: affect.isAsleep)

    eyes.update(
      deltaTime: deltaTime,
      gazeTarget: gazeFrame.target,
      saccade: gazeFrame.saccade,
      expression: eyeExpression,
      blink: blink,
      lidDroop: affect.lidDroop,
      tempo: affect.tempo
    )

    thinkingAmount += ((speechState == .thinking ? 1 : 0) - thinkingAmount)
      * CGFloat(min(1.0, deltaTime * 5.0))

    face.update(
      deltaTime: deltaTime,
      time: time,
      speechState: speechState,
      isListening: isListening,
      eyeExpression: eyeExpression,
      rms: CGFloat(smoothedRms),
      zcr: CGFloat(features.zcr),
      sadness: CGFloat(affect.browSadness),
      thinking: thinkingAmount,
      energy: CGFloat(affect.fidgetEnergy)
    )

    // --- Body color: state hue × mood brightness. Amber = attention (not red),
    // violet = pondering, slate = lost connection.
    var targetColor: SIMD3<Double>
    switch speechState {
    case .agentSpeaking:
      targetColor = SIMD3(0.2, 0.55, 1.0)
    case .userSpeaking:
      targetColor = SIMD3(1.0, 0.62, 0.18)
    case .thinking:
      targetColor = SIMD3(0.58, 0.42, 0.98)
    case .idle:
      targetColor = isListening ? SIMD3(1.0, 0.62, 0.18) : SIMD3(0.2, 0.95, 0.55)
    }
    if isConnectionFailed {
      targetColor = SIMD3(0.5, 0.45, 0.55)
    }
    targetColor *= Double(affect.moodBrightness)
    if affect.isAsleep {
      targetColor *= 0.55
    }

    let colorLerp = min(1.0, deltaTime * 5.5)
    currentColor = lerp(current: currentColor, target: targetColor, amount: colorLerp)
    let baseColor = NSColor(
      calibratedRed: currentColor.x,
      green: currentColor.y,
      blue: currentColor.z,
      alpha: 1.0
    )
    var glowBoost = CGFloat(min(1.0, 0.25 + (smoothedRms * 1.1)))
    if affect.isAsleep {
      glowBoost = 0.12
    }
    orbNode.geometry?.firstMaterial?.diffuse.contents = baseColor
    orbNode.geometry?.firstMaterial?.emission.contents = baseColor.withAlphaComponent(glowBoost)

    currentLightColor = lerp(current: currentLightColor, target: targetColor, amount: colorLerp)
    let lightColor = NSColor(
      calibratedRed: currentLightColor.x,
      green: currentLightColor.y,
      blue: currentLightColor.z,
      alpha: 1.0
    )
    keyLightNode.light?.color = lightColor
    rimLightNode.light?.color = lightColor

    // Modulate particles
    if let ps = particleSystem {
      let targetBirthRate: CGFloat
      switch speechState {
      case .userSpeaking: targetBirthRate = 8
      case .agentSpeaking: targetBirthRate = 12
      case .thinking: targetBirthRate = 6
      case .idle: targetBirthRate = isListening ? 5 : 2
      }
      ps.birthRate = affect.isAsleep ? 0.5 : targetBirthRate
      ps.particleColor = baseColor.withAlphaComponent(0.7)
    }

    // Track state for transition detection
    previousSpeechState = speechState
    previousListening = isListening
    previousConnectionFailed = isConnectionFailed
  }

  func triggerDismissed() {
    affect.apply(event: .dismissed)
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

  private func setupFace() {
    orbNode.addChildNode(eyes.leftEyeNode)
    orbNode.addChildNode(eyes.rightEyeNode)
    orbNode.addChildNode(face.leftBrowNode)
    orbNode.addChildNode(face.rightBrowNode)
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
