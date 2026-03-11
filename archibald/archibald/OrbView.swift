import Combine
import SceneKit
import SwiftUI

struct OrbView: View {
  @EnvironmentObject private var voiceSession: VoiceSessionManager
  @EnvironmentObject private var settings: AppSettings
  @State private var introScale: CGFloat = 0.02

  var body: some View {
    OrbSceneView(voiceSession: voiceSession, orbSize: settings.orbSize, isListening: settings.isListening, isOrbVisible: settings.isOrbVisible)
      .scaleEffect(introScale)
      .onAppear {
        runIntroAnimation()
      }
      .onChange(of: settings.isOrbVisible) { _, isVisible in
        if isVisible {
          runIntroAnimation()
        } else {
          runHideAnimation()
        }
      }
  }

  private func runIntroAnimation() {
    introScale = 0.02
    withAnimation(.easeOut(duration: 0.35)) {
      introScale = 1.08
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
        introScale = 1.0
      }
    }
  }

  private func runHideAnimation() {
    // Delay shrink to let the 3D sad-droop reaction play first
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      withAnimation(.easeInOut(duration: 0.22)) {
        introScale = 0.02
      }
    }
  }
}

private struct OrbSceneView: NSViewRepresentable {
  let voiceSession: VoiceSessionManager
  let orbSize: Double
  let isListening: Bool
  let isOrbVisible: Bool

  func makeNSView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = context.coordinator.orbScene.scene
    view.backgroundColor = .clear
    view.allowsCameraControl = false
    view.rendersContinuously = true
    view.isPlaying = true
    view.delegate = context.coordinator
    context.coordinator.scnView = view
    return view
  }

  func updateNSView(_ nsView: SCNView, context: Context) {
    context.coordinator.updateSize(for: orbSize)
    context.coordinator.bindListening(isListening)
    context.coordinator.updateVisibility(isOrbVisible)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(voiceSession: voiceSession)
  }

  final class Coordinator: NSObject, SCNSceneRendererDelegate {
    let orbScene = OrbScene()
    weak var scnView: SCNView?
    private var cancellables = Set<AnyCancellable>()
    private var latestFeatures = VoiceSessionManager.AudioFeatures(rms: 0, zcr: 0)
    private var latestSpeechState: VoiceSessionManager.SpeechState = .idle
    private var latestListening = false
    private var latestInputLevel: Double = 0

    init(voiceSession: VoiceSessionManager) {
      super.init()
      voiceSession.$outputFeatures
        .receive(on: RunLoop.main)
        .sink { [weak self] features in
          self?.latestFeatures = features
        }
        .store(in: &cancellables)

      voiceSession.$speechState
        .receive(on: RunLoop.main)
        .sink { [weak self] state in
          self?.latestSpeechState = state
        }
        .store(in: &cancellables)

      voiceSession.$inputLevel
        .receive(on: RunLoop.main)
        .sink { [weak self] level in
          self?.latestInputLevel = level
        }
        .store(in: &cancellables)

      voiceSession.$isRecording
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          // Keep orb animation responsive when recording state changes.
          _ = self
        }
        .store(in: &cancellables)
    }

    func updateSize(for orbSize: Double) {
      let scale = max(0.5, min(1.2, CGFloat(orbSize) / 140))
      orbScene.scene.rootNode.scale = SCNVector3(scale, scale, scale)
    }

    private var latestOrbVisible = true

    func bindListening(_ isListening: Bool) {
      latestListening = isListening
    }

    func updateVisibility(_ isVisible: Bool) {
      if !isVisible && latestOrbVisible {
        orbScene.triggerDismissed()
      }
      latestOrbVisible = isVisible
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
      let rmsOverride: Double?
      if latestSpeechState == .userSpeaking || latestListening {
        rmsOverride = latestInputLevel
      } else {
        rmsOverride = nil
      }

      // Convert global mouse position to normalized -1...1 coords relative to SCNView
      var mousePosition: NSPoint?
      if let view = scnView, let window = view.window {
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = view.convert(windowPoint, from: nil)
        let bounds = view.bounds
        if bounds.width > 0 && bounds.height > 0 {
          let nx = (localPoint.x / bounds.width) * 2 - 1
          let ny = (localPoint.y / bounds.height) * 2 - 1
          mousePosition = NSPoint(x: nx, y: ny)
        }
      }

      orbScene.update(
        time: time,
        features: latestFeatures,
        speechState: latestSpeechState,
        isListening: latestListening,
        rmsOverride: rmsOverride,
        mousePosition: mousePosition
      )
    }
  }
}
