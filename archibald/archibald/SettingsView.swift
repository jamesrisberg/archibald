import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var voiceSession: VoiceSessionManager
  @State private var showFolderError = false

  var body: some View {
    Form {
      Section("Orb") {
        Picker("Corner", selection: $settings.corner) {
          ForEach(AppSettings.OrbCorner.allCases) { corner in
            Text(corner.displayName).tag(corner)
          }
        }

        HStack {
          Text("Size")
          Slider(value: $settings.orbSize, in: 64...220, step: 2)
          Text("\(Int(settings.orbSize)) px")
            .frame(width: 64, alignment: .trailing)
          Button("Reset") {
            settings.orbSize = 120
          }
          .buttonStyle(.bordered)
        }

        Toggle("Visible", isOn: $settings.isOrbVisible)
      }

      Section("Voice") {
        Picker("Voice", selection: $settings.voice) {
          ForEach(AppSettings.VoiceOption.allCases) { voice in
            Text(voice.rawValue).tag(voice)
          }
        }

        TextField("System Prompt", text: $settings.systemPrompt, axis: .vertical)
          .lineLimit(3, reservesSpace: true)

        TextField("Ephemeral Token Endpoint", text: $settings.tokenEndpoint)
          .textFieldStyle(.roundedBorder)

        SecureField("xAI API Key (stored locally)", text: $settings.apiKey)
          .textFieldStyle(.roundedBorder)
      }

      Section("Connection") {
        HStack {
          Text("Status")
          Spacer()
          Text(voiceSession.connectionState.rawValue.capitalized)
            .foregroundStyle(.secondary)
        }
                HStack {
                    Text("Input Level")
                    Spacer()
                    ProgressView(value: voiceSession.inputLevel)
                        .frame(width: 140)
                }
                HStack {
                    Text("Output Level")
                    Spacer()
                    ProgressView(value: voiceSession.outputLevel)
                        .frame(width: 140)
                }
        if !voiceSession.lastError.isEmpty {
          Text(voiceSession.lastError)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        Button("Open Microphone Settings") {
          openMicrophoneSettings()
        }
      }

            Section("Transcript") {
                if voiceSession.lastTranscript.isEmpty {
                    Text("No transcript yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(voiceSession.lastTranscript)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

      Section("Shared Inbox") {
        TextField("Folder", text: $settings.inboxFolderPath)
          .textFieldStyle(.roundedBorder)

        HStack {
          Button("Choose Folder…", action: pickInboxFolder)
          Button("Open Folder", action: openInboxFolder)
            .disabled(settings.inboxFolderPath.isEmpty)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 520, idealWidth: 640)
    .alert("Folder unavailable", isPresented: $showFolderError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The shared inbox folder could not be opened.")
    }
  }

  private func pickInboxFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a folder to share with Archibald."

    if panel.runModal() == .OK {
      settings.inboxFolderPath = panel.url?.path ?? ""
    }
  }

  private func openInboxFolder() {
    guard !settings.inboxFolderPath.isEmpty else { return }
    let url = URL(fileURLWithPath: settings.inboxFolderPath)
    if !FileManager.default.fileExists(atPath: url.path) {
      showFolderError = true
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func openMicrophoneSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
