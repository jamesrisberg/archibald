import AVFoundation
import Combine
import Foundation

final class VoiceSessionManager: ObservableObject {
  enum ConnectionState: String {
    case idle
    case connecting
    case connected
    case failed
  }

  @Published private(set) var connectionState: ConnectionState = .idle
  @Published private(set) var inputLevel: Double = 0
  @Published private(set) var outputLevel: Double = 0
  @Published private(set) var outputFeatures = AudioFeatures(rms: 0, zcr: 0)
  @Published private(set) var lastTranscript: String = ""
  @Published private(set) var conversationTranscript: String = ""
  @Published private(set) var lastError: String = ""
  @Published private(set) var serverVoice: String = ""
  enum SpeechState: String {
    case idle
    case userSpeaking
    case agentSpeaking
  }

  @Published private(set) var speechState: SpeechState = .idle
  @Published private(set) var isRecording: Bool = false

  struct AudioFeatures: Equatable {
    let rms: Double
    let zcr: Double
  }

  private enum VAD {
    static let userStartThreshold: Double = 0.07
    static let userStopThreshold: Double = 0.035
    static let userStartHold: TimeInterval = 0.12
    static let userStopHold: TimeInterval = 0.2
    static let agentOutputThreshold: Double = 0.03
    static let agentOutputTail: TimeInterval = 0.4
  }

  private enum Metering {
    static let outputLevelGain: Double = 6.0
    static let rmsAttack: Double = 0.55
    static let rmsRelease: Double = 0.15
    static let zcrAttack: Double = 0.5
    static let zcrRelease: Double = 0.2
  }

  private enum TranscriptStorage {
    static let folderName = "Transcripts"
  }

  private enum DebugStorage {
    static let folderName = "Debug"
  }

  private let settings: AppSettings
  private var webSocketTask: URLSessionWebSocketTask?
  private let audioEngine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private var inputConverter: AVAudioConverter?
  private var outputConverter: AVAudioConverter?
  private var playbackFormat: AVAudioFormat?
  private var outputFrameRatio: Double = 1.0
  private var pingTimer: DispatchSourceTimer?
  private var isStopping = false
  private var hasSentAudio = false
  private var pendingStartCapture = false
  private var pendingResponseCreate = false
  private var pendingResponseTimer: DispatchWorkItem?
  private var currentListeningState = false
  private var isPlayingResponse = false
  private var userSpeechActive = false
  private var userSpeechStartCandidateAt: Date?
  private var userSpeechStopCandidateAt: Date?
  private var agentSpeechActive = false
  private var scheduledAudioBuffers = 0
  private var lastAudioDeltaAt = Date.distantPast
  private var playbackMonitor: DispatchSourceTimer?
  private var speakingResetWorkItem: DispatchWorkItem?
  private var lastOutputActivityAt = Date.distantPast
  private var hasOutputTap = false
  private var smoothedOutputRms: Double = 0
  private var smoothedOutputZcr: Double = 0
  private var responseDoneAt = Date.distantPast
  private var lastAudioEndAt = Date.distantPast
  private var cancellables = Set<AnyCancellable>()
  private var wsLogEntries: [String] = []
  private var transcriptFileURL: URL?
  private let transcriptFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  private let inputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)

  init(settings: AppSettings) {
    self.settings = settings
    bindSettings()
    setupPlayback()
  }

  func startListening() {
    if connectionState == .connected {
      setLastError("")
      isStopping = false
      hasSentAudio = false
      setIsRecording(true)
      startAudioCapture()
      return
    }
    guard connectionState == .idle || connectionState == .failed else { return }
    setLastError("")
    isStopping = false
    hasSentAudio = false
    pendingStartCapture = true
    Task {
      let granted = await requestMicAccess()
      guard granted else {
        setLastError("Microphone access denied.")
        await MainActor.run {
          settings.isListening = false
        }
        await sendMicrophoneDeniedNotice()
        return
      }
      await connect(withAudio: true)
    }
  }

  func stopListening() {
    isStopping = true
    if connectionState == .connected {
      finalizeTurn()
    }
    currentListeningState = false
    setInputLevel(0)
    setOutputLevel(0)
    setIsRecording(false)
    stopAudioCapture()
    stopEngineIfIdle(force: true)
  }

  private func bindSettings() {
    settings.$isListening
      .sink { [weak self] (isListening: Bool) in
        guard let self else { return }
        DispatchQueue.main.async {
          self.currentListeningState = isListening
        }
        if isListening {
          self.startListening()
        } else {
          self.stopListening()
        }
      }
      .store(in: &cancellables)

    settings.$systemPrompt
      .sink { [weak self] _ in
        self?.sendSessionUpdate()
      }
      .store(in: &cancellables)

    settings.$voice
      .sink { [weak self] _ in
        self?.sendSessionUpdate()
      }
      .store(in: &cancellables)
  }

  private func requestMicAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      break
    @unknown default:
      return false
    }
    return await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func connect(withAudio: Bool) async {
    guard connectionState == .idle else { return }
    setConnectionState(.connecting)
    setLastError("")

    do {
      let apiKey = settings.apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      guard !apiKey.isEmpty else {
        setConnectionState(.failed)
        setLastError("API key is required.")
        await MainActor.run {
          settings.isListening = false
        }
        return
      }

      let client = GrokVoiceClient()
      let token = try await client.fetchEphemeralToken(apiKey: apiKey)

      var request = URLRequest(url: client.sessionEndpoint)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      let task = URLSession.shared.webSocketTask(with: request)
      webSocketTask = task
      task.resume()
      setConnectionState(.connected)
      startTranscriptSession()

      pendingStartCapture = withAudio
      sendSessionUpdate()
      receiveLoop()
      startPing()
    } catch {
      setConnectionState(.failed)
      let message = (error as NSError).localizedDescription
      setLastError("Failed to connect: \(message)")
      await MainActor.run {
        settings.isListening = false
      }
    }
  }

  private func sendSessionUpdate() {
    let config: [String: Any] = [
      "type": "session.update",
      "session": [
        "voice": settings.voice.rawValue,
        "instructions": settings.systemPrompt,
        "keep_context": true,
        "turn_detection": ["type": nil],
        "modalities": ["audio", "text"],
        "audio": [
          "input": ["format": ["type": "audio/pcm", "rate": 24000]],
          "output": ["format": ["type": "audio/pcm", "rate": 24000]],
        ],
      ],
    ]

    sendJSON(config)
  }

  private func receiveLoop() {
    webSocketTask?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        self.handleMessage(message)
        self.receiveLoop()
      case .failure(let error):
        if self.connectionState == .connected && !self.isStopping {
          self.setLastError("WebSocket disconnected: \(error.localizedDescription)")
        }
        self.setConnectionState(.failed)
        Task { @MainActor in
          self.settings.isListening = false
        }
      }
    }
  }

  private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    let data: Data
    switch message {
    case .data(let payload):
      data = payload
    case .string(let text):
      data = Data(text.utf8)
    @unknown default:
      return
    }

    logIncomingEvent(data)
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let type = json["type"] as? String
    else { return }

    switch type {
    case "response.output_audio.delta":
      if let delta = json["delta"] as? String {
        isPlayingResponse = true
        lastAudioDeltaAt = Date()
        startPlaybackMonitor()
        playAudioDelta(delta)
      }
    case "input_audio_buffer.speech_started":
      break
    case "input_audio_buffer.speech_stopped":
      break
    case "input_audio_buffer.committed":
      if pendingResponseCreate {
        pendingResponseCreate = false
        sendResponseCreate()
      }
    case "response.output_text.delta":
      if let delta = json["delta"] as? String {
        DispatchQueue.main.async {
          self.lastTranscript += delta
        }
      }
    case "response.output_text.done":
      DispatchQueue.main.async {
        self.lastTranscript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    case "response.output_audio_transcript.delta":
      if let delta = json["delta"] as? String {
        DispatchQueue.main.async {
          self.lastTranscript += delta
        }
      }
    case "conversation.item.input_audio_transcription.completed":
      if let transcript = json["transcript"] as? String {
        appendTranscript(role: "You", text: transcript)
      }
    case "error":
      if let error = json["error"] as? [String: Any],
        let message = error["message"] as? String
      {
        setLastError("Server error: \(message)")
      }
    case "response.output_audio_transcript.done":
      if let transcript = json["transcript"] as? String {
        appendTranscript(role: "Archibald", text: transcript)
      }
      DispatchQueue.main.async {
        self.lastTranscript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    case "response.output_audio.done":
      isPlayingResponse = false
      lastAudioEndAt = Date()
      break
    case "conversation.created":
      if pendingStartCapture {
        pendingStartCapture = false
        startAudioCapture()
      }
    case "response.done":
      if isStopping {
        isStopping = false
        hasSentAudio = false
      }
      isPlayingResponse = false
      responseDoneAt = Date()
    case "response.created":
      DispatchQueue.main.async {
        self.lastTranscript = ""
      }
    case "session.updated":
      if let session = json["session"] as? [String: Any],
        let voice = session["voice"] as? String
      {
        DispatchQueue.main.async {
          self.serverVoice = voice
        }
      }
    default:
      if type.hasPrefix("response.") || type.hasPrefix("conversation.")
        || type.hasPrefix("input_audio_buffer.")
      {
        setLastError("Last event: \(type)")
      }
      break
    }
  }

  private func startAudioCapture() {
    guard let inputFormat else { return }
    let inputNode = audioEngine.inputNode

    let hardwareFormat = inputNode.outputFormat(forBus: 0)
    inputConverter = AVAudioConverter(from: hardwareFormat, to: inputFormat)
    outputFrameRatio = inputFormat.sampleRate / hardwareFormat.sampleRate

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) {
      [weak self] buffer, _ in
      guard let self else { return }
      self.processInputBuffer(buffer, inputFormat: inputFormat)
    }

    do {
      if !audioEngine.isRunning {
        try audioEngine.start()
      }
    } catch {
      setConnectionState(.failed)
      settings.isListening = false
    }
  }

  private func processInputBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
    guard let converter = inputConverter else { return }
    let targetFrames = max(1, Int(ceil(Double(buffer.frameLength) * outputFrameRatio)))
    guard
      let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: AVAudioFrameCount(targetFrames)
      )
    else { return }

    var error: NSError?
    var didProvideInput = false
    converter.convert(to: pcmBuffer, error: &error) { _, outStatus in
      if !didProvideInput {
        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
      }
      outStatus.pointee = .noDataNow
      return nil
    }

    guard error == nil else { return }
    guard let channelData = pcmBuffer.int16ChannelData else { return }

    let frameLength = Int(pcmBuffer.frameLength)
    let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
    guard let baseAddress = samples.baseAddress else { return }
    let data = Data(bytes: baseAddress, count: frameLength * MemoryLayout<Int16>.size)

    updateInputLevel(samples: samples)
    sendAudioData(data)
  }

  private func updateInputLevel(samples: UnsafeBufferPointer<Int16>) {
    guard !samples.isEmpty else { return }
    let rms = sqrt(
      samples.reduce(0.0) { sum, value in
        let sample = Double(value)
        return sum + (sample * sample)
      } / Double(samples.count))
    let normalized = min(1, rms / Double(Int16.max))
    setInputLevel(normalized)
    updateUserSpeechState(level: normalized)
  }

  private func sendAudioData(_ data: Data) {
    guard connectionState == .connected else { return }
    if (isPlayingResponse || agentSpeechActive) && currentListeningState && !isStopping {
      interruptResponsePlayback()
      sendJSON(["type": "response.cancel"])
    }
    let base64 = data.base64EncodedString()
    let message: [String: Any] = [
      "type": "input_audio_buffer.append",
      "audio": base64,
    ]
    hasSentAudio = true
    sendJSON(message)
  }

  private func playAudioDelta(_ base64: String) {
    ensureAudioEngineRunning()
    guard let data = Data(base64Encoded: base64), let outputFormat else { return }
    let frameCount = data.count / 2
    guard frameCount > 0 else { return }

    guard
      let sourceBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else { return }
    sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

    data.withUnsafeBytes { rawBuffer in
      guard let int16Buffer = rawBuffer.bindMemory(to: Int16.self).baseAddress,
        let channelData = sourceBuffer.int16ChannelData
      else { return }
      channelData[0].update(from: int16Buffer, count: frameCount)
    }

    updateOutputLevel(buffer: sourceBuffer)

    if let outputConverter, let playbackFormat {
      let ratio = playbackFormat.sampleRate / outputFormat.sampleRate
      let targetFrames = max(1, Int(ceil(Double(frameCount) * ratio)))
      guard
        let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: playbackFormat,
          frameCapacity: AVAudioFrameCount(targetFrames)
        )
      else { return }

      var error: NSError?
      var didProvideInput = false
      outputConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
        if !didProvideInput {
          didProvideInput = true
          outStatus.pointee = .haveData
          return sourceBuffer
        }
        outStatus.pointee = .noDataNow
        return nil
      }

      guard error == nil else { return }
      enqueuePlayback(buffer: convertedBuffer)
    } else {
      enqueuePlayback(buffer: sourceBuffer)
    }

    if !playerNode.isPlaying {
      playerNode.play()
    }
  }

  private func updateOutputLevel(buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.int16ChannelData else { return }
    let frameLength = Int(buffer.frameLength)
    let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
    let rms = sqrt(
      samples.reduce(0.0) { sum, value in
        let sample = Double(value)
        return sum + (sample * sample)
      } / Double(samples.count))
    let normalized = min(1, (rms / Double(Int16.max)) * Metering.outputLevelGain)
    setOutputLevel(normalized)
    if playerNode.isPlaying && normalized > VAD.agentOutputThreshold {
      lastOutputActivityAt = Date()
    }
  }

  private func updateOutputFeatures(samples: UnsafeBufferPointer<Float>) {
    guard !samples.isEmpty else { return }
    var sumSquares = 0.0
    var zeroCrossings = 0
    var lastSign = samples[0] >= 0
    for sample in samples {
      let value = Double(sample)
      sumSquares += value * value
      let sign = sample >= 0
      if sign != lastSign {
        zeroCrossings += 1
        lastSign = sign
      }
    }
    let rms = sqrt(sumSquares / Double(samples.count))
    let scaledRms = min(1.0, rms * Metering.outputLevelGain)
    let zcr = min(1.0, Double(zeroCrossings) / Double(samples.count))

    let nextRms = smoothValue(
      current: smoothedOutputRms,
      target: scaledRms,
      attack: Metering.rmsAttack,
      release: Metering.rmsRelease
    )
    let nextZcr = smoothValue(
      current: smoothedOutputZcr,
      target: zcr,
      attack: Metering.zcrAttack,
      release: Metering.zcrRelease
    )
    smoothedOutputRms = nextRms
    smoothedOutputZcr = nextZcr
    setOutputFeatures(AudioFeatures(rms: nextRms, zcr: nextZcr))
  }

  private func smoothValue(current: Double, target: Double, attack: Double, release: Double)
    -> Double
  {
    let amount = target > current ? attack : release
    return current + (target - current) * amount
  }

  private func installOutputTapIfNeeded(format: AVAudioFormat) {
    guard !hasOutputTap else { return }
    hasOutputTap = true
    audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) {
      [weak self] buffer, _ in
      guard let self else { return }
      guard let channelData = buffer.floatChannelData else { return }
      let frameLength = Int(buffer.frameLength)
      if frameLength == 0 { return }
      let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
      let rms = sqrt(
        samples.reduce(0.0) { sum, value in
          let sample = Double(value)
          return sum + (sample * sample)
        } / Double(samples.count))
      let normalized = min(1, rms * Metering.outputLevelGain)
      DispatchQueue.main.async {
        self.setOutputLevel(normalized)
        if self.playerNode.isPlaying && normalized > VAD.agentOutputThreshold {
          self.lastOutputActivityAt = Date()
        }
        self.updateOutputFeatures(samples: samples)
      }
    }
  }

  private func removeOutputTapIfNeeded() {
    guard hasOutputTap else { return }
    audioEngine.mainMixerNode.removeTap(onBus: 0)
    hasOutputTap = false
  }

  private func setupPlayback() {
    audioEngine.attach(playerNode)
    let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
    playbackFormat = mixerFormat
    if let outputFormat {
      outputConverter = AVAudioConverter(from: outputFormat, to: mixerFormat)
      if outputConverter == nil {
        setLastError("Audio output converter unavailable.")
      }
    }
    audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: mixerFormat)
    installOutputTapIfNeeded(format: mixerFormat)
  }

  private func stopAudio() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    removeOutputTapIfNeeded()
    playerNode.stop()
    playerNode.reset()
    stopPlaybackMonitor()
    userSpeechActive = false
    agentSpeechActive = false
    setSpeechState(.idle)
    setIsRecording(false)
  }

  private func ensureAudioEngineRunning() {
    guard !audioEngine.isRunning else { return }
    do {
      try audioEngine.start()
    } catch {
      setLastError("Audio engine failed to start: \(error.localizedDescription)")
    }
  }

  private func stopEngineIfIdle(force: Bool = false) {
    if !force {
      guard !currentListeningState else { return }
    }
    guard scheduledAudioBuffers == 0, !playerNode.isPlaying else { return }
    if audioEngine.isRunning {
      audioEngine.stop()
    }
  }

  private func startPlaybackMonitor() {
    guard playbackMonitor == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(deadline: .now(), repeating: 0.1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let agentActive =
        self.scheduledAudioBuffers > 0
      self.updateSpeechState(userActive: self.userSpeechActive, agentActive: agentActive)
      if !agentActive {
        self.stopPlaybackMonitor()
      }
    }
    playbackMonitor = timer
    timer.resume()
  }

  private func stopPlaybackMonitor() {
    playbackMonitor?.cancel()
    playbackMonitor = nil
  }

  private func enqueuePlayback(buffer: AVAudioPCMBuffer) {
    scheduledAudioBuffers += 1
    playerNode.scheduleBuffer(
      buffer,
      completionHandler: { [weak self] in
        DispatchQueue.main.async {
          guard let self else { return }
          self.scheduledAudioBuffers = max(0, self.scheduledAudioBuffers - 1)
          self.updateSpeechState(
            userActive: self.userSpeechActive, agentActive: self.scheduledAudioBuffers > 0)
          if self.scheduledAudioBuffers == 0 {
            self.playerNode.stop()
            self.stopEngineIfIdle()
          }
        }
      })
  }

  private func updateUserSpeechState(level: Double) {
    let now = Date()

    if level >= VAD.userStartThreshold {
      userSpeechStartCandidateAt = userSpeechStartCandidateAt ?? now
      userSpeechStopCandidateAt = nil
      if !userSpeechActive,
        let startAt = userSpeechStartCandidateAt,
        now.timeIntervalSince(startAt) >= VAD.userStartHold
      {
        userSpeechActive = true
        onUserSpeechStarted()
      }
    } else if level <= VAD.userStopThreshold {
      userSpeechStopCandidateAt = userSpeechStopCandidateAt ?? now
      userSpeechStartCandidateAt = nil
      if userSpeechActive,
        let stopAt = userSpeechStopCandidateAt,
        now.timeIntervalSince(stopAt) >= VAD.userStopHold
      {
        userSpeechActive = false
        updateSpeechState(userActive: false, agentActive: agentSpeechActive)
      }
    } else {
      userSpeechStartCandidateAt = nil
      userSpeechStopCandidateAt = nil
    }
  }

  private func onUserSpeechStarted() {
    updateSpeechState(userActive: true, agentActive: agentSpeechActive)
    if agentSpeechActive || isPlayingResponse {
      interruptResponsePlayback()
      sendJSON(["type": "response.cancel"])
    }
  }

  private func updateSpeechState(userActive: Bool, agentActive: Bool) {
    agentSpeechActive = agentActive
    let nextState: SpeechState
    if userActive {
      nextState = .userSpeaking
    } else if agentActive {
      nextState = .agentSpeaking
    } else {
      nextState = .idle
    }
    if speechState != nextState {
      setSpeechState(nextState)
    }
  }

  private func interruptResponsePlayback() {
    guard isPlayingResponse else { return }
    DispatchQueue.main.async {
      self.playerNode.stop()
      self.playerNode.reset()
      self.isPlayingResponse = false
    }
  }

  private func stopAudioCapture() {
    audioEngine.inputNode.removeTap(onBus: 0)
    stopEngineIfIdle(force: true)
  }

  private func stopWebSocket() {
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
  }

  private func finalizeTurn() {
    guard hasSentAudio else { return }
    pendingResponseCreate = true
    sendJSON(["type": "input_audio_buffer.commit"])
    scheduleResponseCreateFallback()
  }

  private func sendResponseCreate() {
    sendSessionUpdate()
    let response: [String: Any] = [
      "type": "response.create",
      "response": [
        "modalities": ["audio", "text"],
        "instructions": settings.systemPrompt,
        "voice": settings.voice.rawValue,
      ],
    ]
    sendJSON(response)
  }

  private func scheduleResponseCreateFallback() {
    pendingResponseTimer?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.pendingResponseCreate else { return }
      self.pendingResponseCreate = false
      self.sendResponseCreate()
    }
    pendingResponseTimer = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
  }

  private func startPing() {
    stopPing()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "archibald.ws.ping"))
    timer.schedule(deadline: .now() + 10, repeating: 10)
    timer.setEventHandler { [weak self] in
      guard let self, self.connectionState == .connected else { return }
      self.webSocketTask?.sendPing { [weak self] error in
        guard let self else { return }
        if let error {
          self.setLastError("WebSocket ping failed: \(error.localizedDescription)")
          Task { @MainActor in
            self.settings.isListening = false
          }
        }
      }
    }
    pingTimer = timer
    timer.resume()
  }

  private func stopPing() {
    pingTimer?.cancel()
    pingTimer = nil
  }

  private func sendJSON(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    guard webSocketTask?.state == .running else { return }
    logOutgoingEvent(data)
    if let text = String(data: data, encoding: .utf8) {
      webSocketTask?.send(.string(text)) { _ in }
    } else {
      webSocketTask?.send(.data(data)) { _ in }
    }
  }

  private func logOutgoingEvent(_ data: Data) {
    logEvent(direction: "OUT", data: data)
  }

  private func logIncomingEvent(_ data: Data) {
    logEvent(direction: "IN", data: data)
  }

  private func logEvent(direction: String, data: Data) {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      let message = "[Grok WS \(direction)] <non-JSON payload>"
      appendWsLog(message)
      DebugLog.log(message)
      return
    }
    let type = (json["type"] as? String) ?? "unknown"
    var scrubbed = json
    if type == "input_audio_buffer.append" {
      scrubbed["audio"] = "<\(data.count) bytes>"
    }
    if type == "session.update",
      var session = scrubbed["session"] as? [String: Any],
      var audio = session["audio"] as? [String: Any]
    {
      audio["input"] = "<redacted>"
      audio["output"] = "<redacted>"
      session["audio"] = audio
      scrubbed["session"] = session
    }
    if let text = try? JSONSerialization.data(withJSONObject: scrubbed),
      let string = String(data: text, encoding: .utf8)
    {
      let maxLength = 1200
      let truncated =
        string.count > maxLength ? String(string.prefix(maxLength)) + "…<truncated>" : string
      let message = "[Grok WS \(direction)] \(type) \(truncated)"
      appendWsLog(message)
      DebugLog.log(message)
    } else {
      let message = "[Grok WS \(direction)] \(type)"
      appendWsLog(message)
      DebugLog.log(message)
    }
  }

  private func appendWsLog(_ message: String) {
    let timestamp = transcriptFormatter.string(from: Date())
    wsLogEntries.append("[\(timestamp)] \(message)")
    let maxEntries = 300
    if wsLogEntries.count > maxEntries {
      wsLogEntries.removeFirst(wsLogEntries.count - maxEntries)
    }
  }

  private func setConnectionState(_ state: ConnectionState) {
    DispatchQueue.main.async {
      self.connectionState = state
    }
  }

  private func setInputLevel(_ level: Double) {
    DispatchQueue.main.async {
      self.inputLevel = level
    }
  }

  private func setOutputLevel(_ level: Double) {
    DispatchQueue.main.async {
      self.outputLevel = level
    }
  }

  private func setOutputFeatures(_ features: AudioFeatures) {
    DispatchQueue.main.async {
      self.outputFeatures = features
    }
  }

  private func setLastError(_ message: String) {
    DispatchQueue.main.async {
      self.lastError = message
    }
  }

  private func setSpeechState(_ value: SpeechState) {
    DispatchQueue.main.async {
      self.speechState = value
    }
  }

  private func setIsRecording(_ value: Bool) {
    DispatchQueue.main.async {
      self.isRecording = value
    }
  }

  private func sendMicrophoneDeniedNotice() async {
    guard connectionState == .idle || connectionState == .failed else { return }
    await connect(withAudio: false)
    guard connectionState == .connected else { return }
    let message: [String: Any] = [
      "type": "conversation.item.create",
      "item": [
        "type": "message",
        "role": "user",
        "content": [
          [
            "type": "input_text",
            "text":
              "I can't access the microphone. Please enable microphone permission in Settings so I can hear you.",
          ]
        ],
      ],
    ]
    sendJSON(message)
    sendJSON(["type": "response.create"])
  }

  private func startTranscriptSession() {
    conversationTranscript = ""
    transcriptFileURL = createTranscriptFileURL()
    if let url = transcriptFileURL {
      let header = "Archibald Transcript (\(transcriptFormatter.string(from: Date())))\n\n"
      writeTranscriptData(header.data(using: .utf8), to: url, overwrite: true)
    }
  }

  private func appendTranscript(role: String, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let timestamp = transcriptFormatter.string(from: Date())
    let line = "[\(timestamp)] \(role): \(trimmed)\n"
    DispatchQueue.main.async {
      self.conversationTranscript += line
    }
    if let url = transcriptFileURL {
      writeTranscriptData(line.data(using: .utf8), to: url, overwrite: false)
    }
  }

  private func createTranscriptFileURL() -> URL? {
    guard let folderURL = transcriptFolderURL() else { return nil }
    let timestamp = Date().formatted(.dateTime.year().month().day().hour().minute().second())
    return folderURL.appendingPathComponent("Session \(timestamp).txt")
  }

  private func writeTranscriptData(_ data: Data?, to url: URL, overwrite: Bool) {
    guard let data else { return }
    if overwrite {
      try? data.write(to: url, options: .atomic)
      return
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }

  func transcriptFolderURL() -> URL? {
    let fileManager = FileManager.default
    guard
      let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    let folderURL = baseURL.appendingPathComponent("Archibald", isDirectory: true)
      .appendingPathComponent(TranscriptStorage.folderName, isDirectory: true)
    do {
      try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    return folderURL
  }

  func clearTranscript() {
    DispatchQueue.main.async {
      self.lastTranscript = ""
      self.conversationTranscript = ""
    }
    if let url = transcriptFileURL {
      writeTranscriptData(Data(), to: url, overwrite: true)
    }
  }

  func exportVoiceDebugLog() -> URL? {
    let fileManager = FileManager.default
    guard
      let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    let folderURL = baseURL.appendingPathComponent("Archibald", isDirectory: true)
      .appendingPathComponent(DebugStorage.folderName, isDirectory: true)
    do {
      try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    } catch {
      return nil
    }

    let timestamp = Date().formatted(.dateTime.year().month().day().hour().minute().second())
    let fileURL = folderURL.appendingPathComponent("VoiceDebug \(timestamp).txt")
    var lines: [String] = []
    lines.append("Archibald Voice Debug Log")
    lines.append("Timestamp: \(timestamp)")
    lines.append("Selected Voice: \(settings.voice.rawValue)")
    lines.append("Server Voice: \(serverVoice.isEmpty ? "—" : serverVoice)")
    lines.append("Speech State: \(speechState.rawValue)")
    lines.append("")
    lines.append("WebSocket Log:")
    lines.append(contentsOf: wsLogEntries)
    let body = lines.joined(separator: "\n")
    try? body.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    return fileURL
  }

  func resetSession() {
    pendingResponseTimer?.cancel()
    pendingResponseTimer = nil
    isStopping = false
    hasSentAudio = false
    pendingStartCapture = false
    pendingResponseCreate = false
    stopPing()
    stopWebSocket()
    stopAudio()
    setConnectionState(.idle)
    setLastError("")
    DispatchQueue.main.async {
      self.lastTranscript = ""
      self.conversationTranscript = ""
    }
    transcriptFileURL = nil
    Task { @MainActor in
      self.settings.isListening = false
    }
  }
}
