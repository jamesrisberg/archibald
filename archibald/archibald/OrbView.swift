import Combine
import SwiftUI

struct OrbView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var voiceSession: VoiceSessionManager

  @State private var displayLevel: Double = 0
  @State private var lastDisplayLevel: Double = 0
  private let decayTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

  private var audioLevel: Double {
    max(voiceSession.inputLevel, voiceSession.outputLevel)
  }

  private var effectiveLevel: Double {
    switch voiceSession.speechState {
    case .agentSpeaking:
      return max(voiceSession.outputLevel, 0.08)
    case .userSpeaking:
      return max(voiceSession.inputLevel, 0.2)
    case .idle:
      return audioLevel
    }
  }

  private var pulseScale: CGFloat {
    let agentBoost = voiceSession.speechState == .agentSpeaking ? 0.06 : 0.0
    let userBoost = voiceSession.speechState == .userSpeaking ? 0.1 : 0.0
    let listeningBoost = voiceSession.isRecording ? 0.06 : 0.0
    return CGFloat(0.9 + (displayLevel * 0.28) + agentBoost + userBoost + listeningBoost)
  }

  private var glowOpacity: Double {
    0.25 + (displayLevel * 0.95)
  }

  private var orbColors: (primary: Color, secondary: Color, deep: Color) {
    if voiceSession.speechState == .agentSpeaking {
      return (
        Color(red: 0.35, green: 0.7, blue: 1.0),
        Color(red: 0.18, green: 0.45, blue: 0.95),
        Color(red: 0.05, green: 0.12, blue: 0.35)
      )
    }

    if settings.isListening {
      return (
        Color(red: 1.0, green: 0.18, blue: 0.2),
        Color(red: 0.85, green: 0.08, blue: 0.12),
        Color(red: 0.35, green: 0.02, blue: 0.04)
      )
    }

    return (
      Color(red: 0.35, green: 0.95, blue: 0.6),
      Color(red: 0.2, green: 0.7, blue: 0.45),
      Color(red: 0.05, green: 0.2, blue: 0.12)
    )
  }

  var body: some View {
    TimelineView(.animation) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      let slowSpin = Angle.degrees(time * (8 + (displayLevel * 80)))
      let fastSpin = Angle.degrees(time * (24 + (displayLevel * 160)))
      let shimmer = 0.5 + (0.5 * sin(time * 3.2 + (displayLevel * 12)))
      let ripple = 0.1 + (displayLevel * 0.45)
      let agentWave =
        voiceSession.speechState == .agentSpeaking ? 0.05 * sin(time * 3.2) : 0.0
      let userWave =
        settings.isListening ? 0.02 * sin(time * 3.8) : 0.0
      let orbScale = pulseScale + CGFloat(agentWave + userWave)
      let colors = orbColors

      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                colors.primary.opacity(0.95),
                colors.secondary.opacity(0.9),
                colors.deep.opacity(0.95),
              ],
              center: .center,
              startRadius: 4,
              endRadius: settings.orbSize / 1.05
            )
          )
          .overlay(
            Circle()
              .fill(
                RadialGradient(
                  colors: [
                    Color.white.opacity(0.35),
                    Color.white.opacity(0.12),
                    Color.clear,
                  ],
                  center: .center,
                  startRadius: 0,
                  endRadius: settings.orbSize / 1.4
                )
              )
              .blendMode(.screen)
          )
          .overlay(
            Circle()
              .stroke(Color.white.opacity(0.25), lineWidth: 1)
          )
          .scaleEffect(orbScale)

        Circle()
          .strokeBorder(
            AngularGradient(
              colors: [
                Color(red: 0.6, green: 0.85, blue: 1.0).opacity(0.0),
                Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.6 + displayLevel * 0.4),
                Color(red: 0.2, green: 0.5, blue: 1.0).opacity(0.0),
              ],
              center: .center,
              angle: slowSpin
            ),
            lineWidth: 6 + (displayLevel * 18)
          )
          .blur(radius: 8)
          .opacity(glowOpacity * shimmer)

        Circle()
          .strokeBorder(
            AngularGradient(
              colors: [
                Color(red: 0.3, green: 0.8, blue: 1.0),
                Color(red: 0.1, green: 0.45, blue: 0.95),
                Color(red: 0.3, green: 0.8, blue: 1.0),
              ],
              center: .center,
              angle: fastSpin
            ),
            lineWidth: 2 + (displayLevel * 6)
          )
          .blur(radius: 2)
          .opacity(0.35 + (displayLevel * 0.65))

        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color.white.opacity(0.85),
                Color.white.opacity(0.0),
              ],
              center: .center,
              startRadius: 0,
              endRadius: settings.orbSize / 2.6
            )
          )
          .blendMode(.screen)
          .opacity(0.6 + (displayLevel * 0.5))

        Circle()
          .stroke(colors.primary.opacity(0.55), lineWidth: 3)
          .scaleEffect(1.0 + ripple)
          .opacity(0.3 + (displayLevel * 0.9))
          .blur(radius: 12)
      }
      .frame(width: settings.orbSize, height: settings.orbSize)
      .padding(OrbLayout.contentPadding(orbSize: settings.orbSize))
      .frame(
        width: OrbLayout.outerSize(orbSize: settings.orbSize),
        height: OrbLayout.outerSize(orbSize: settings.orbSize)
      )
      .onChange(of: audioLevel) { _, newValue in
        let agentBias = voiceSession.speechState == .agentSpeaking ? 0.2 : 0
        let userBias = settings.isListening ? 0.32 : 0
        let boosted = min(0.75, effectiveLevel * 4.2 + agentBias + userBias)
        let smoothed = (lastDisplayLevel * 0.65) + (boosted * 0.35)
        displayLevel = max(smoothed, displayLevel * 0.94)
        lastDisplayLevel = displayLevel
      }
      .onReceive(decayTimer) { _ in
        let floorLevel =
          voiceSession.speechState == .agentSpeaking ? 0.16 : (settings.isListening ? 0.16 : 0.0)
        let decayStep = voiceSession.speechState == .agentSpeaking ? 0.012 : 0.013
        let decayed = max(displayLevel - decayStep, floorLevel)
        displayLevel = decayed
        lastDisplayLevel = displayLevel
      }
    }
    .contentShape(Circle())
    .onTapGesture {
      settings.isListening.toggle()
    }
    .animation(.easeInOut(duration: 0.12), value: pulseScale)
    .animation(.easeInOut(duration: 0.4), value: voiceSession.speechState)
    .accessibilityLabel("Archibald")
    .accessibilityHint("Click to start or stop listening")
  }
}
