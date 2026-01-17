//
//  archibaldApp.swift
//  archibald
//
//  Created by James Risberg on 1/16/26.
//

import SwiftUI

@main
struct archibaldApp: App {
  @StateObject private var settings: AppSettings
  @StateObject private var voiceSession: VoiceSessionManager
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    let settings = AppSettings()
    let voiceSession = VoiceSessionManager(settings: settings)
    _settings = StateObject(wrappedValue: settings)
    _voiceSession = StateObject(wrappedValue: voiceSession)
    appDelegate.settings = settings
    appDelegate.voiceSession = voiceSession
  }

  var body: some Scene {
    MenuBarExtra("Archibald", systemImage: "sparkles") {
      VStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "sparkles")
            .foregroundStyle(.secondary)
          Text("Archibald")
            .font(.headline)
          Spacer()
          Text(settings.isListening ? "Listening" : "Idle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        MenuActionButton(
          title: settings.isOrbVisible ? "Hide Orb" : "Show Orb",
          systemImage: settings.isOrbVisible ? "eye.slash" : "eye",
          action: { settings.isOrbVisible.toggle() }
        )

        MenuActionButton(
          title: settings.isListening ? "Stop Listening" : "Start Listening",
          systemImage: settings.isListening ? "stop.circle" : "mic.circle",
          action: { settings.isListening.toggle() }
        )

        Divider()
          .overlay(Color.white.opacity(0.15))

        SettingsLink {
          MenuActionRow(
            title: "Settings",
            systemImage: "slider.horizontal.3"
          )
        }
        .buttonStyle(.plain)

        Divider()
          .overlay(Color.white.opacity(0.15))

        MenuActionButton(
          title: "Quit Archibald",
          systemImage: "power",
          role: .destructive,
          action: { NSApplication.shared.terminate(nil) }
        )
      }
      .padding(12)
      .frame(minWidth: 240)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color.white.opacity(0.12), lineWidth: 1)
      )
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandMenu("Archibald") {
        Button("Show/Toggle Listening") {
          handlePrimaryShortcut()
        }
        .keyboardShortcut("\\", modifiers: [.shift])

        Button("Hide Orb") {
          settings.isOrbVisible = false
          settings.isListening = false
        }
        .keyboardShortcut("\\", modifiers: [.command, .shift])
      }
    }
    Settings {
      SettingsView()
        .environmentObject(settings)
        .environmentObject(voiceSession)
    }
  }
}

extension archibaldApp {
  private func handlePrimaryShortcut() {
    if !settings.isOrbVisible {
      settings.isOrbVisible = true
      settings.isListening = true
      return
    }
    settings.isListening.toggle()
  }
}

