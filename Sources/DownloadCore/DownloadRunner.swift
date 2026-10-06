import Foundation
import Darwin

/// Each queue job owns a process and staging directory. Cancellation and the
/// publication ACK share one lock, so a saved book cannot be called cancelled.
public final class DownloadRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let executionQueue = DispatchQueue(label: "FanFicToAudio.download-process", qos: .userInitiated)
    private var process: Process?
    private var cancelled = false
    private var finalizing = false
    public init() {}

    @discardableResult public func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finalizing else { return false }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return true
    }

    public func run(_ request: DownloadRequest, executable: URL, arguments: [String] = [],
                    onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> DownloadEvent {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                executionQueue.async { [self] in
                    do { continuation.resume(returning: try runSync(request, executable: executable, arguments: arguments, onEvent: onEvent)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func runSync(_ original: DownloadRequest, executable: URL, arguments: [String],
                         onEvent: @escaping @Sendable (DownloadEvent) -> Void) throws -> DownloadEvent {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("fanfic-job-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        var request = original
        var work: URL?
        if ["download", "update"].contains(request.operation) {
            let destination = request.operation == "update"
                ? URL(fileURLWithPath: request.source).deletingLastPathComponent()
                : URL(fileURLWithPath: request.output)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let staging = destination.appendingPathComponent(".fff-work-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            work = staging
            request.work_dir = staging.path
        }
        defer { if let work { try? fm.removeItem(at: work) } }
        let requestFile = temporary.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestFile, options: .atomic)
        // Selected settings may contain private paths. Keep the request owner-only.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestFile.path)
        let errorFile = temporary.appendingPathComponent("stderr")
        fm.createFile(atPath: errorFile.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorFile)
        defer { try? errors.close() }
        let input = Pipe(), output = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments + ["--request", requestFile.path]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() }
        catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        // Close parent copies of the child's pipe ends so EOF is observable.
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        var buffer = Data()
        var result: DownloadEvent?
        var reportedError: String?
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            guard buffer.count <= 4 * 1024 * 1024 else {
                throw DownloadError.message("The download helper returned an oversized response.")
            }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let event = try JSONDecoder().decode(DownloadEvent.self, from: line)
                if event.finalizing == true {
                    lock.lock()
                    if cancelled { lock.unlock(); throw CancellationError() }
                    finalizing = true
                    do { try input.fileHandleForWriting.write(contentsOf: Data("commit\n".utf8)) }
                    catch { lock.unlock(); throw error }
                    lock.unlock()
                }
                if event.type == "result" { result = event }
                if event.type == "error" { reportedError = event.message ?? "Download failed." }
                onEvent(event)
            }
        }
        child.waitUntilExit()
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        if let reportedError { throw DownloadError.message(reportedError) }
        guard child.terminationStatus == 0, let result else {
            throw DownloadError.message("The download helper stopped before returning a complete result (exit \(child.terminationStatus)). Retry the job or rebuild the application.")
        }
        guard buffer.isEmpty else { throw DownloadError.message("The download helper returned an incomplete response.") }
        return result
    }
}
