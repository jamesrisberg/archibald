import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var voiceSession: VoiceSessionManager
  @State private var showFolderError = false
  @State private var showTranscriptFolderError = false
  @State private var showApiKeyInfo = false
  @State private var showClearTranscriptConfirm = false

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        SettingsSection(title: "Layout") {
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
          }

          HStack {
            MenuActionButton(title: "Reset Size", systemImage: "arrow.counterclockwise") {
              settings.orbSize = 120
            }
            .frame(maxWidth: 220, alignment: .leading)
            Spacer()
          }
        }

        SettingsSection(title: "Agent") {
          Picker("Voice", selection: $settings.voice) {
            ForEach(AppSettings.VoiceOption.allCases) { voice in
              Text(voice.rawValue).tag(voice)
            }
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("System Prompt")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            TextField(
              "You are Archibald, a concise desktop assistant.", text: $settings.systemPrompt,
              axis: .vertical
            )
            .lineLimit(3, reservesSpace: true)
          }

          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
              Text("XAI Voice Agent API Key")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              Button {
                showApiKeyInfo = true
              } label: {
                Image(systemName: "info.circle")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
            }
            SecureField("Paste your API key", text: $settings.apiKey)
              .textFieldStyle(.roundedBorder)
          }
        }

        SettingsSection(title: "System") {
          Picker("Keyboard Shortcut", selection: $settings.primaryHotKey) {
            ForEach(AppSettings.HotKeyOption.allCases) { option in
              Text(option.displayName).tag(option)
            }
          }

          MenuActionButton(
            title: "Open Microphone Settings", systemImage: "mic", action: openMicrophoneSettings)
        }

        SettingsSection(title: "Memory & Transcript") {
          MenuActionButton(title: "Start New Session", systemImage: "arrow.triangle.2.circlepath") {
            voiceSession.resetSession()
          }

          HStack(spacing: 10) {
            MenuActionButton(title: "Open Transcript Folder", systemImage: "folder") {
              openTranscriptFolder()
            }
            MenuActionButton(title: "Clear Transcript", systemImage: "trash", role: .destructive) {
              showClearTranscriptConfirm = true
            }
          }

          if voiceSession.conversationTranscript.isEmpty {
            Text("No transcript yet.")
              .foregroundStyle(.secondary)
          } else {
            ScrollView {
              Text(voiceSession.conversationTranscript)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)
          }
        }

        SettingsSection(title: "Shared Inbox") {
          TextField("Folder", text: $settings.inboxFolderPath)
            .textFieldStyle(.roundedBorder)

          HStack(spacing: 10) {
            MenuActionButton(
              title: "Choose Folder", systemImage: "folder.badge.plus", action: pickInboxFolder)
            MenuActionButton(title: "Open Folder", systemImage: "folder", action: openInboxFolder)
              .disabled(settings.inboxFolderPath.isEmpty)
          }
        }

        SettingsSection(title: "Debug") {
          Toggle("Debug Logging", isOn: $settings.debugLogging)

          HStack {
            Text("Status")
            Spacer()
            Text(voiceSession.connectionState.rawValue.capitalized)
              .foregroundStyle(.secondary)
          }
          HStack {
            Text("Speech State")
            Spacer()
            Text(voiceSession.speechState.rawValue)
              .foregroundStyle(.secondary)
          }
          HStack {
            Text("Recording")
            Spacer()
            Text(voiceSession.isRecording ? "On" : "Off")
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
        }
      }
      .padding(24)
    }
    .frame(minWidth: 560, idealWidth: 680)
    .onAppear {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
    }
    .alert("Folder unavailable", isPresented: $showFolderError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The shared inbox folder could not be opened.")
    }
    .alert("Transcript folder unavailable", isPresented: $showTranscriptFolderError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("The transcript folder could not be opened.")
    }
    .alert("Clear transcript?", isPresented: $showClearTranscriptConfirm) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        voiceSession.clearTranscript()
      }
    } message: {
      Text("This will clear the current session transcript and remove its saved contents.")
    }
    .alert("Get your API key", isPresented: $showApiKeyInfo) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Create or copy your key from https://console.x.ai. Paste it here to connect.")
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

  private func openTranscriptFolder() {
    guard let url = voiceSession.transcriptFolderURL() else {
      showTranscriptFolderError = true
      return
    }
    NSWorkspace.shared.open(url)
  }
}

private struct SettingsSection<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      VStack(alignment: .leading, spacing: 12) {
        content
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
  }
}
