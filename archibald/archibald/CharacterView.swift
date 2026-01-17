import Combine
import SceneKit
import SwiftUI

struct CharacterView: NSViewRepresentable {
  @EnvironmentObject private var voiceSession: VoiceSessionManager
  @EnvironmentObject private var settings: AppSettings

  func makeNSView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = context.coordinator.character.scene
    view.backgroundColor = .clear
    view.allowsCameraControl = false
    view.rendersContinuously = true
    view.isPlaying = true
    view.delegate = context.coordinator
    return view
  }

  func updateNSView(_ nsView: SCNView, context: Context) {
    context.coordinator.updateSize(for: settings.orbSize)
    context.coordinator.bindListening(settings.isListening)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(voiceSession: voiceSession)
  }

  final class Coordinator: NSObject, SCNSceneRendererDelegate {
    let character = CharacterScene()
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
      character.scene.rootNode.scale = SCNVector3(scale, scale, scale)
    }

    func bindListening(_ isListening: Bool) {
      latestListening = isListening
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
      let rmsOverride: Double?
      if latestSpeechState == .userSpeaking || latestListening {
        rmsOverride = latestInputLevel
      } else {
        rmsOverride = nil
      }
      character.update(
        features: latestFeatures,
        speechState: latestSpeechState,
        isListening: latestListening,
        rmsOverride: rmsOverride
      )
    }
  }
}
