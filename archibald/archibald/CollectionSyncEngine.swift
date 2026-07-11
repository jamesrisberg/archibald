import Combine
import CryptoKit
import Foundation

/// Mirrors a local folder into an xAI Collection.
/// The folder is the source of truth: missing-on-disk → detach from cloud,
/// changed-on-disk → re-upload (since xAI files are immutable, "change" = detach old + upload new).
final class CollectionSyncEngine: ObservableObject {
  enum SyncStatus: Equatable {
    case idle
    case syncing(progress: String)
    case error(String)
  }

  struct ManifestEntry: Codable {
    var fileID: String
    var contentHash: String
    var size: Int
    var uploadedAt: Date
  }

  private struct Manifest: Codable {
    var entries: [String: ManifestEntry] = [:]
  }

  @Published private(set) var status: SyncStatus = .idle
  @Published private(set) var fileCount: Int = 0
  @Published private(set) var lastSyncedAt: Date?

  private let settings: AppSettings
  private var manifest: Manifest = Manifest()
  private var inFlight: Task<Void, Never>?
  private var createTask: Task<Void, Never>?
  private var watcher: FolderWatcher?
  private var cancellables = Set<AnyCancellable>()
  /// Resolved & scope-held while the engine is active. Sandbox requires us to
  /// keep this open to read files from a user-picked folder.
  private var activeScopedURL: URL?

  /// 100MB — xAI's per-file upload limit.
  private static let maxFileSize: Int = 100 * 1024 * 1024

  init(settings: AppSettings) {
    self.settings = settings
    loadManifest()
    fileCount = manifest.entries.count

    // React to enable/disable + key/folder/collection changes by restarting.
    Publishers.CombineLatest4(
      settings.$fileCollectionsEnabled,
      settings.$collectionFolderPath,
      settings.$collectionID,
      settings.$xaiManagementAPIKey
    )
    .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
    .sink { [weak self] _, _, _, _ in self?.restartIfReady() }
    .store(in: &cancellables)
  }

  // MARK: - Public

  func restartIfReady() {
    stop()
    guard settings.fileCollectionsEnabled,
          !settings.collectionFolderPath.isEmpty,
          !settings.xaiManagementAPIKey.isEmpty,
          !settings.apiKey.isEmpty
    else {
      DispatchQueue.main.async { self.status = .idle }
      return
    }

    guard let folderURL = settings.resolveCollectionFolderURL() else {
      DispatchQueue.main.async {
        self.status = .error("Folder access lost — re-pick the synced folder.")
      }
      return
    }

    // Auto-create the collection on first run so the user doesn't have to.
    // Setting settings.collectionID re-triggers this method via the Combine pipeline.
    if settings.collectionID.isEmpty {
      autoCreateCollection()
      return
    }

    if folderURL.startAccessingSecurityScopedResource() {
      activeScopedURL = folderURL
    } else {
      DispatchQueue.main.async {
        self.status = .error("Sandbox denied access to folder. Re-pick the folder.")
      }
      return
    }

    let watcher = FolderWatcher(url: folderURL) { [weak self] in
      self?.reconcile()
    }
    self.watcher = watcher
    watcher.start()
    reconcile()
  }

  func stop() {
    watcher?.stop()
    watcher = nil
    inFlight?.cancel()
    inFlight = nil
    createTask?.cancel()
    createTask = nil
    if let url = activeScopedURL {
      url.stopAccessingSecurityScopedResource()
      activeScopedURL = nil
    }
  }

  private func autoCreateCollection() {
    if createTask != nil { return }
    DispatchQueue.main.async { self.status = .syncing(progress: "Creating collection…") }
    let api = CollectionAPI(
      apiKey: settings.apiKey,
      managementKey: settings.xaiManagementAPIKey
    )
    let folderName = URL(fileURLWithPath: settings.collectionFolderPath).lastPathComponent
    let name = folderName.isEmpty
      ? "Archibald-\(Int(Date().timeIntervalSince1970))"
      : "Archibald-\(folderName)"
    createTask = Task { [weak self] in
      defer {
        Task { @MainActor in self?.createTask = nil }
      }
      do {
        let id = try await api.createCollection(name: name)
        await MainActor.run {
          self?.settings.collectionID = id  // triggers restartIfReady()
        }
      } catch {
        await MainActor.run {
          self?.status = .error("Could not create collection: \(error.localizedDescription)")
        }
      }
    }
  }

  /// Run a full diff pass against the cloud. Safe to call repeatedly — coalesces.
  func reconcile() {
    if inFlight != nil { return }
    inFlight = Task { [weak self] in
      await self?.runReconcile()
      await MainActor.run { self?.inFlight = nil }
    }
  }

  // MARK: - Reconcile

  @MainActor
  private func setStatus(_ s: SyncStatus) {
    self.status = s
  }

  private func runReconcile() async {
    await setStatus(.syncing(progress: "Scanning folder…"))

    guard let folderURL = activeScopedURL else {
      await setStatus(.error("No active folder. Re-pick the synced folder."))
      return
    }
    let collectionID = settings.collectionID
    let api = CollectionAPI(apiKey: settings.apiKey, managementKey: settings.xaiManagementAPIKey)

    let local: [String: (url: URL, hash: String, size: Int)]
    do {
      local = try scanFolder(folderURL)
    } catch {
      await setStatus(.error("Scan failed: \(error.localizedDescription)"))
      return
    }

    // Diff
    var toUpload: [String] = []
    var toDelete: [String] = []
    for (relPath, info) in local {
      if let m = manifest.entries[relPath] {
        if m.contentHash != info.hash {
          toUpload.append(relPath)
        }
      } else {
        toUpload.append(relPath)
      }
    }
    for relPath in manifest.entries.keys where local[relPath] == nil {
      toDelete.append(relPath)
    }

    if toUpload.isEmpty && toDelete.isEmpty {
      await setStatus(.idle)
      await MainActor.run {
        self.fileCount = self.manifest.entries.count
        self.lastSyncedAt = Date()
      }
      return
    }

    var failed: [String] = []
    let total = toUpload.count + toDelete.count
    var done = 0

    for relPath in toUpload {
      await setStatus(.syncing(progress: "Uploading \(relPath) (\(done + 1)/\(total))"))
      guard let info = local[relPath] else { continue }
      do {
        // Replace pattern: detach old (if any) → upload → attach. A failed
        // detach must fail the whole replace — uploading anyway would leave
        // the stale document attached alongside the new one. The manifest is
        // untouched on failure, so the next reconcile retries.
        if let old = manifest.entries[relPath] {
          try await api.detach(collectionID: collectionID, fileID: old.fileID)
        }
        let fileID = try await api.uploadFile(localURL: info.url)
        try await api.attach(collectionID: collectionID, fileID: fileID)
        manifest.entries[relPath] = ManifestEntry(
          fileID: fileID,
          contentHash: info.hash,
          size: info.size,
          uploadedAt: Date()
        )
        saveManifest()
      } catch {
        failed.append("\(relPath): \(error.localizedDescription)")
      }
      done += 1
    }

    for relPath in toDelete {
      await setStatus(.syncing(progress: "Removing \(relPath) (\(done + 1)/\(total))"))
      guard let entry = manifest.entries[relPath] else { continue }
      do {
        try await api.detach(collectionID: collectionID, fileID: entry.fileID)
        manifest.entries.removeValue(forKey: relPath)
        saveManifest()
      } catch {
        failed.append("\(relPath): \(error.localizedDescription)")
      }
      done += 1
    }

    await MainActor.run {
      self.fileCount = self.manifest.entries.count
      self.lastSyncedAt = Date()
    }
    if failed.isEmpty {
      await setStatus(.idle)
    } else {
      await setStatus(.error("\(failed.count) failure(s): \(failed.prefix(3).joined(separator: "; "))"))
    }
  }

  // MARK: - Folder scan

  private func scanFolder(_ root: URL) throws -> [String: (url: URL, hash: String, size: Int)] {
    var result: [String: (url: URL, hash: String, size: Int)] = [:]
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return result
    }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { continue }
      let size = values.fileSize ?? 0
      if size > Self.maxFileSize { continue }
      let relPath = url.path.replacingOccurrences(of: root.path + "/", with: "")
      let data = try Data(contentsOf: url)
      let hash = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
      result[relPath] = (url, hash, size)
    }
    return result
  }

  // MARK: - Manifest persistence

  private static let manifestFileName = "collection-manifest.json"

  private func manifestURL() -> URL? {
    guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let appDir = dir.appendingPathComponent("Archibald", isDirectory: true)
    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    return appDir.appendingPathComponent(Self.manifestFileName)
  }

  private func loadManifest() {
    guard let url = manifestURL(),
          let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else {
      return
    }
    manifest = decoded
  }

  private func saveManifest() {
    guard let url = manifestURL() else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(manifest) {
      try? data.write(to: url, options: .atomic)
    }
  }

  // MARK: - Snapshot for confirmation gate

  /// Used to surface a confirmation in the UI before mass-deletion.
  var manifestSnapshotCount: Int { manifest.entries.count }

  /// Wipe the local manifest without touching the cloud (e.g. when user
  /// confirms they want to keep cloud state but re-bind to a new folder).
  func wipeLocalManifestKeepCloud() {
    manifest = Manifest()
    saveManifest()
    DispatchQueue.main.async {
      self.fileCount = 0
    }
  }
}

// MARK: - FolderWatcher (FSEvents)

private final class FolderWatcher {
  private let url: URL
  private let onChange: () -> Void
  private var stream: FSEventStreamRef?
  private var pending: DispatchWorkItem?

  init(url: URL, onChange: @escaping () -> Void) {
    self.url = url
    self.onChange = onChange
  }

  func start() {
    stop()
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil, release: nil, copyDescription: nil
    )
    let paths = [url.path] as CFArray
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
      watcher.scheduleDebounced()
    }
    guard let stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      &context,
      paths,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.5,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    ) else { return }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
  }

  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    pending?.cancel()
    pending = nil
  }

  private func scheduleDebounced() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.onChange() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
  }

  deinit { stop() }
}
