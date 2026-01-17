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

  init() {
    scene = SCNScene()
    setupCamera()
    setupLighting()
    setupOrb()
  }

  func update(
    features: VoiceSessionManager.AudioFeatures,
    speechState: VoiceSessionManager.SpeechState,
    isListening: Bool,
    rmsOverride: Double?
  ) {
    hoverPhase += 0.05
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
    orbNode.scale = SCNVector3(
      Float(combinedScale),
      Float(combinedScale),
      Float(combinedScale)
    )
    orbNode.position = SCNVector3(0, Float(hover), 0)

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

  private func lerp(current: CGFloat, target: CGFloat, amount: CGFloat) -> CGFloat {
    current + (target - current) * amount
  }

  private func lerp(current: SIMD3<Double>, target: SIMD3<Double>, amount: Double) -> SIMD3<Double>
  {
    current + (target - current) * amount
  }
}
