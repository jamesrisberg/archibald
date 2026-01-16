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
  @Published private(set) var lastTranscript: String = ""
  @Published private(set) var lastError: String = ""

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
  private var cancellables = Set<AnyCancellable>()

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
    setInputLevel(0)
    setOutputLevel(0)
    stopAudioCapture()
  }

  private func bindSettings() {
    settings.$isListening
      .sink { [weak self] (isListening: Bool) in
        guard let self else { return }
        if isListening {
          self.startListening()
        } else {
          self.stopListening()
        }
      }
      .store(in: &cancellables)

    Publishers.CombineLatest(settings.$voice, settings.$systemPrompt)
      .sink { [weak self] _, _ in
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
      let tokenURL: URL
      if apiKey.isEmpty {
        guard let parsedURL = URL(string: settings.tokenEndpoint) else {
          setConnectionState(.failed)
          setLastError("Invalid token endpoint URL.")
          await MainActor.run {
            settings.isListening = false
          }
          return
        }
        tokenURL = parsedURL
      } else {
        tokenURL = URL(string: "https://api.x.ai")!
      }

      let client = GrokVoiceClient(tokenEndpoint: tokenURL)
      let token: String
      if apiKey.isEmpty {
        token = try await client.fetchEphemeralToken()
      } else {
        token = try await client.fetchEphemeralToken(apiKey: apiKey)
      }

      var request = URLRequest(url: client.sessionEndpoint)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      let task = URLSession.shared.webSocketTask(with: request)
      webSocketTask = task
      task.resume()
      setConnectionState(.connected)

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
        playAudioDelta(delta)
      }
    case "input_audio_buffer.speech_started":
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
    case "error":
      if let error = json["error"] as? [String: Any],
        let message = error["message"] as? String
      {
        setLastError("Server error: \(message)")
      }
    case "response.output_audio_transcript.done":
      DispatchQueue.main.async {
        self.lastTranscript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    case "response.output_audio.done":
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
        setConnectionState(.idle)
        stopPing()
        stopWebSocket()
      }
    case "response.created":
      DispatchQueue.main.async {
        self.lastTranscript = ""
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
  }

  private func sendAudioData(_ data: Data) {
    guard connectionState == .connected else { return }
    let base64 = data.base64EncodedString()
    let message: [String: Any] = [
      "type": "input_audio_buffer.append",
      "audio": base64,
    ]
    hasSentAudio = true
    sendJSON(message)
  }

  private func playAudioDelta(_ base64: String) {
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
      playerNode.scheduleBuffer(convertedBuffer, completionHandler: nil)
    } else {
      playerNode.scheduleBuffer(sourceBuffer, completionHandler: nil)
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
    let normalized = min(1, rms / Double(Int16.max))
    setOutputLevel(normalized)
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
  }

  private func stopAudio() {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    playerNode.stop()
  }

  private func stopAudioCapture() {
    audioEngine.inputNode.removeTap(onBus: 0)
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
      NSLog("[Grok WS \(direction)] <non-JSON payload>")
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
      NSLog("[Grok WS \(direction)] \(type) \(truncated)")
    } else {
      NSLog("[Grok WS \(direction)] \(type)")
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

  private func setLastError(_ message: String) {
    DispatchQueue.main.async {
      self.lastError = message
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
}
