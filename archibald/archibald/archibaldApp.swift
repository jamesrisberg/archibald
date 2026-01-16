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
      Button(settings.isOrbVisible ? "Hide Orb" : "Show Orb") {
        settings.isOrbVisible.toggle()
      }
      Button(settings.isListening ? "Stop Listening" : "Start Listening") {
        settings.isListening.toggle()
      }
      Divider()
      SettingsLink {
        Text("Settings…")
      }
      Divider()
      Button("Quit Archibald") {
        NSApplication.shared.terminate(nil)
      }
    }
    .menuBarExtraStyle(.window)
    Settings {
      SettingsView()
        .environmentObject(settings)
        .environmentObject(voiceSession)
    }
  }
}
