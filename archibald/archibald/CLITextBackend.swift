import Foundation

/// Runs a CLI tool with the user message on **stdin** and reads **stdout** as the reply.
/// Point `executablePath` at `claude`, `codex`, or a small wrapper script that invokes them with the right flags.
struct CLITextBackend: AgentTextBackend {
  let executablePath: String
  let arguments: [String]
  let workingDirectoryPath: String

  private static let timeoutSeconds: TimeInterval = 600

  func respond(userMessage: String, systemPrompt: String?) async throws -> String {
    let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      throw AgentTextError.missingExecutable("Set the executable path in Settings.")
    }
    guard FileManager.default.fileExists(atPath: path) else {
      throw AgentTextError.missingExecutable("File not found: \(path)")
    }
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw AgentTextError.missingExecutable("Not executable: \(path)")
    }

    var payload = userMessage
    if let system = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
      payload = "[System]\n\(system)\n\n[User]\n\(userMessage)"
    }
    guard let inputData = (payload + "\n").data(using: .utf8) else {
      throw AgentTextError.missingExecutable("Could not encode message.")
    }

    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        let cwd = workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) {
          task.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
          try task.run()
        } catch {
          cont.resume(throwing: error)
          return
        }

        stdinPipe.fileHandleForWriting.write(inputData)
        stdinPipe.fileHandleForWriting.closeFile()

        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
          task.waitUntilExit()
          waitGroup.leave()
        }

        if waitGroup.wait(timeout: .now() + Self.timeoutSeconds) == .timedOut {
          task.terminate()
          cont.resume(throwing: AgentTextError.cliTimeout)
          return
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard task.terminationStatus == 0 else {
          let err = String(data: errData, encoding: .utf8) ?? ""
          cont.resume(throwing: AgentTextError.cliNonZero(task.terminationStatus, err))
          return
        }

        let text = String(data: outData, encoding: .utf8) ?? ""
        cont.resume(
          returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
  }
}
