import Foundation
import Darwin

public struct ProcessOutput: Sendable {
    public let standardOutput: String
    public let standardError: String
}

// Each operation owns a runner. Cancellation and process launch share a lock so
// cancelling between two commands cannot leave the next command running.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false
    private var timedOut = false
    private let cancellationGrace: TimeInterval
    private let commandTimeout: TimeInterval
    public init(cancellationGrace: TimeInterval = 1, commandTimeout: TimeInterval = 1800) {
        self.cancellationGrace = max(0.05, cancellationGrace)
        self.commandTimeout = max(0.05, commandTimeout)
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        if let active { terminate(active) }
        lock.unlock()
    }

    // Called under the lock. Identity checks prevent a delayed signal reaching
    // a later command or a reused process identifier.
    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + cancellationGrace) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if active === process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func expire(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard active === process, process.isRunning else { return }
        timedOut = true
        terminate(process)
    }

    public func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
    }

    public func run(_ executable: URL, arguments: [String]) async throws -> ProcessOutput {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached { [self] in try runSync(executable, arguments: arguments) }.value
        } onCancel: { self.cancel() }
    }

    private func runSync(_ executable: URL, arguments: [String]) throws -> ProcessOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epub-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        active = process
        timedOut = false
        do { try process.run() }
        catch { active = nil; lock.unlock(); throw error }
        lock.unlock()
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.setEventHandler { [weak self] in self?.expire(process) }
        deadline.schedule(deadline: .now() + commandTimeout)
        deadline.resume()
        process.waitUntilExit()
        deadline.setEventHandler {}
        deadline.cancel()
        lock.lock()
        active = nil
        let stopped = cancelled
        let expired = timedOut
        lock.unlock()
        if stopped { throw CancellationError() }
        if expired { throw AudiobookError.conversion("\(executable.lastPathComponent) exceeded its command timeout. Completed passages are retained for retry.") }
        let stdout = try tail(outURL)
        let stderr = try tail(errURL)
        guard process.terminationStatus == 0 else {
            throw AudiobookError.conversion("\(executable.lastPathComponent) failed (\(process.terminationStatus)). \(stderr.isEmpty ? stdout : stderr)")
        }
        return ProcessOutput(standardOutput: stdout, standardError: stderr)
    }

    private func tail(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SpeechTools {
    public static let say = URL(fileURLWithPath: "/usr/bin/say")

    public static func voices(runner: ProcessRunner = ProcessRunner()) async throws -> [SystemVoice] {
        let result = try await runner.run(say, arguments: ["-v", "?"])
        let voices = SystemVoice.parse(result.standardOutput)
        guard !voices.isEmpty else { throw AudiobookError.conversion("macOS did not report any speech voices.") }
        return voices
    }

    public static func findFFmpeg() -> URL? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) { candidates.append(bundled.path) }
        if let saved = UserDefaults.standard.string(forKey: "ffmpegPath") { candidates.append(saved) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func verifyFFmpeg(_ url: URL, runner: ProcessRunner, mode: ExportMode = .single) async throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AudiobookError.conversion("Select an executable FFmpeg binary to encode audiobook audio.")
        }
        let result = try await runner.run(url, arguments: ["-hide_banner", "-encoders"])
        guard result.standardOutput.contains(mode == .m4b ? " aac " : "libmp3lame") else {
            let encoder = mode == .m4b ? "AAC" : "libmp3lame MP3"
            throw AudiobookError.conversion("This FFmpeg build does not include the \(encoder) encoder.")
        }
    }
}
