import SwiftUI

struct OrbView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var voiceSession: VoiceSessionManager

    private var pulseScale: CGFloat {
        let level = max(voiceSession.inputLevel, voiceSession.outputLevel)
        let listeningBoost = settings.isListening ? 0.03 : 0.0
        return CGFloat(0.95 + (level * 0.12) + listeningBoost)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.67, green: 0.86, blue: 1.0),
                            Color(red: 0.24, green: 0.45, blue: 0.95)
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: settings.orbSize / 1.2
                    )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
                .scaleEffect(pulseScale)
                .shadow(color: Color.blue.opacity(0.55), radius: 18, x: 0, y: 0)
                .shadow(color: Color.white.opacity(0.25), radius: 4, x: 0, y: 0)
        }
        .frame(width: settings.orbSize, height: settings.orbSize)
        .contentShape(Circle())
        .onTapGesture {
            settings.isListening.toggle()
        }
        .animation(.easeInOut(duration: 0.12), value: pulseScale)
        .accessibilityLabel("Archibald")
        .accessibilityHint("Click to start or stop listening")
    }
}
