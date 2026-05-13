import AppKit
import Combine
import Sparkle
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var voiceSession: VoiceSessionManager
  @EnvironmentObject private var collectionSync: CollectionSyncEngine
  @State private var showFolderError = false
  @State private var showTranscriptFolderError = false
  @State private var showApiKeyInfo = false
  @State private var showClearTranscriptConfirm = false
  @State private var showDebugExportError = false
  @State private var showDestructiveFolderConfirm = false
  @State private var pendingFolderPath: String?
  @State private var pendingFolderBookmark: Data?

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

        SettingsSection(title: "Voice (Grok)") {
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

        SettingsSection(title: "Text agent") {
          Picker("Provider", selection: $settings.textAgentProvider) {
            ForEach(AppSettings.TextAgentProvider.allCases) { provider in
              Text(provider.displayName).tag(provider)
            }
          }

          Text(
            "Optional second brain: Ollama over HTTP, or a CLI (stdin → stdout). Wire voice to this in a later build."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          if settings.textAgentProvider == .ollama {
            TextField("Base URL", text: $settings.ollamaBaseURLString)
              .textFieldStyle(.roundedBorder)
            TextField("Model", text: $settings.ollamaModel)
              .textFieldStyle(.roundedBorder)
          }

          if settings.textAgentProvider == .claudeCode {
            TextField("Executable path (e.g. /opt/homebrew/bin/claude)", text: $settings.claudeCodeExecutablePath)
              .textFieldStyle(.roundedBorder)
            TextField("Extra arguments (comma-separated)", text: $settings.claudeCodeArgumentsString)
              .textFieldStyle(.roundedBorder)
          }

          if settings.textAgentProvider == .codex {
            TextField("Executable path", text: $settings.codexExecutablePath)
              .textFieldStyle(.roundedBorder)
            TextField("Extra arguments (comma-separated)", text: $settings.codexArgumentsString)
              .textFieldStyle(.roundedBorder)
          }

          if settings.textAgentProvider == .claudeCode || settings.textAgentProvider == .codex {
            TextField("Working directory (optional)", text: $settings.agentWorkingDirectoryPath)
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

        SettingsSection(title: "File Collections") {
          Toggle("Enable file collections", isOn: $settings.fileCollectionsEnabled)

          if settings.fileCollectionsEnabled {
            VStack(alignment: .leading, spacing: 6) {
              Text("XAI Management API Key")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              SecureField("Paste your management key", text: $settings.xaiManagementAPIKey)
                .textFieldStyle(.roundedBorder)
              Text("Separate from the voice API key. Used to create collections and attach files.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
              Text("Synced Folder")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              TextField("Folder", text: .constant(settings.collectionFolderPath.isEmpty
                ? "No folder chosen"
                : settings.collectionFolderPath))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
              HStack(spacing: 10) {
                MenuActionButton(
                  title: "Choose Folder",
                  systemImage: "folder.badge.plus",
                  action: pickCollectionFolder)
                MenuActionButton(
                  title: "Open Folder",
                  systemImage: "folder",
                  action: openCollectionFolder
                )
                .disabled(settings.collectionFolderBookmark == nil)
              }
            }

            VStack(alignment: .leading, spacing: 6) {
              Text("Collection ID")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              TextField("Auto-created on first run", text: $settings.collectionID)
                .textFieldStyle(.roundedBorder)
              Text("Created automatically once a key and folder are set. Paste an existing ID here if you want to reuse a collection.")
                .font(.caption)
                .foregroundStyle(.secondary)
              MenuActionButton(
                title: "Sync Now",
                systemImage: "arrow.triangle.2.circlepath",
                action: { collectionSync.reconcile() }
              )
              .disabled(settings.collectionID.isEmpty || settings.collectionFolderPath.isEmpty)
            }

            HStack {
              Text("Status")
              Spacer()
              Text(syncStatusDisplay)
                .foregroundStyle(syncStatusColor)
                .font(.caption)
            }
            HStack {
              Text("Files")
              Spacer()
              Text("\(collectionSync.fileCount)")
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            if let last = collectionSync.lastSyncedAt {
              HStack {
                Text("Last sync")
                Spacer()
                Text(last.formatted(date: .omitted, time: .standard))
                  .foregroundStyle(.secondary)
                  .font(.caption)
              }
            }
          }
        }

        SettingsSection(title: "Updates") {
          CheckForUpdatesView()
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
            Text("Selected Voice")
            Spacer()
            Text(settings.voice.rawValue)
              .foregroundStyle(.secondary)
          }
          HStack {
            Text("Server Voice")
            Spacer()
            Text(voiceSession.serverVoice.isEmpty ? "—" : voiceSession.serverVoice)
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

          MenuActionButton(title: "Export Voice Debug Log", systemImage: "doc.text.magnifyingglass")
          {
            if let url = voiceSession.exportVoiceDebugLog() {
              NSWorkspace.shared.open(url)
            } else {
              showDebugExportError = true
            }
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
      Text("The collection folder could not be opened.")
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
    .alert("Export failed", isPresented: $showDebugExportError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Could not create the debug log file.")
    }
    .alert("Replace synced folder?", isPresented: $showDestructiveFolderConfirm) {
      Button("Cancel", role: .cancel) {
        pendingFolderPath = nil
        pendingFolderBookmark = nil
      }
      Button("Replace & re-sync", role: .destructive) {
        settings.collectionFolderBookmark = pendingFolderBookmark
        if let path = pendingFolderPath {
          settings.collectionFolderPath = path
        }
        pendingFolderPath = nil
        pendingFolderBookmark = nil
      }
      Button("Keep cloud, drop local manifest") {
        collectionSync.wipeLocalManifestKeepCloud()
        settings.collectionFolderBookmark = pendingFolderBookmark
        if let path = pendingFolderPath {
          settings.collectionFolderPath = path
        }
        pendingFolderPath = nil
        pendingFolderBookmark = nil
      }
    } message: {
      Text("The current synced folder has \(collectionSync.fileCount) tracked file(s) in the cloud. Switching folders will detach them from the collection. Choose how to proceed.")
    }
  }

  private var syncStatusDisplay: String {
    switch collectionSync.status {
    case .idle: return "Up to date"
    case .syncing(let progress): return progress
    case .error(let message): return message
    }
  }

  private var syncStatusColor: Color {
    switch collectionSync.status {
    case .idle: return .secondary
    case .syncing: return .blue
    case .error: return .red
    }
  }

  private func pickCollectionFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose a folder to mirror into the xAI collection."

    guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
    let chosenPath = chosenURL.path

    let bookmark: Data?
    do {
      bookmark = try chosenURL.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      bookmark = nil
    }

    if collectionSync.fileCount > 0 && chosenPath != settings.collectionFolderPath {
      pendingFolderPath = chosenPath
      pendingFolderBookmark = bookmark
      showDestructiveFolderConfirm = true
    } else {
      settings.collectionFolderBookmark = bookmark
      settings.collectionFolderPath = chosenPath
    }
  }

  private func openCollectionFolder() {
    guard let url = settings.resolveCollectionFolderURL() else {
      showFolderError = true
      return
    }
    let started = url.startAccessingSecurityScopedResource()
    defer { if started { url.stopAccessingSecurityScopedResource() } }
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

private struct CheckForUpdatesView: View {
  @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

  init() {
    let updater = (NSApp.delegate as? AppDelegate)?.updaterController.updater
    self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    MenuActionButton(
      title: "Check for Updates",
      systemImage: "arrow.triangle.2.circlepath"
    ) {
      (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
    }
    .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
  }
}

private final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false
  private var cancellable: AnyCancellable?

  init(updater: SPUUpdater?) {
    guard let updater else { return }
    cancellable = updater.publisher(for: \.canCheckForUpdates)
      .assign(to: \.canCheckForUpdates, on: self)
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
