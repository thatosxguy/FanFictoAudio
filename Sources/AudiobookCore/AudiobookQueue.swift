import Foundation
import Combine

public enum AudiobookJobState: String, Sendable {
    case queued = "Queued", running = "Converting", done = "Done", failed = "Failed", cancelled = "Cancelled"
}

public struct AudiobookJob: Identifiable, Sendable {
    public let id = UUID()
    public let source: URL
    public var title: String
    public var author = ""
    public var state: AudiobookJobState = .queued
    public var progress = 0.0
    public var message = "Waiting to convert."
    public var output: URL?
    public let chapterIDs: Set<String>?

    public init(source: URL, chapterIDs: Set<String>? = nil) {
        self.source = source
        self.title = source.deletingPathExtension().lastPathComponent
        self.chapterIDs = chapterIDs
    }
}

public struct BatchNarrationSettings: Sendable {
    public let voice: String
    public let wordsPerMinute: Int
    public let bitrate: Int
    public let mode: ExportMode
    public let ffmpeg: URL
    public let api: APINarration?
    public init(voice: String, wordsPerMinute: Int, bitrate: Int, mode: ExportMode, ffmpeg: URL, api: APINarration? = nil) {
        self.voice = voice; self.wordsPerMinute = wordsPerMinute; self.bitrate = bitrate
        self.mode = mode; self.ffmpeg = ffmpeg; self.api = api
    }
}

/// Reads one EPUB at a time and reuses the transactional audiobook exporter.
@MainActor
public final class AudiobookQueue: ObservableObject {
    public typealias Reader = @Sendable (URL) async throws -> EPUBBook
    public typealias Exporter = @Sendable (EPUBBook, ExportOptions, URL, ProcessRunner, @escaping @Sendable (ExportProgress) -> Void) async throws -> URL

    @Published public private(set) var jobs: [AudiobookJob] = []
    @Published public private(set) var activeBook: (id: UUID, book: EPUBBook)?
    @Published public private(set) var isRunning = false
    @Published public private(set) var summary = "Add EPUBs to create several audiobooks."
    @Published public private(set) var batchProgress = 0.0
    private let reader: Reader
    private let exporter: Exporter
    private var task: Task<Void, Never>?
    private var runner: ProcessRunner?
    private var pauseRequested = false
    private var batchIDs: [UUID] = []
    private var batchFinished = 0

    public init(reader: @escaping Reader = { url in
        try await EPUBLibrary.shared.read(url)
    }, exporter: @escaping Exporter = { book, options, destination, runner, progress in
        try await AudiobookExporter.export(book: book, options: options, destination: destination,
            runner: runner, progress: progress)
    }) {
        self.reader = reader; self.exporter = exporter
    }

    public var queuedCount: Int { jobs.filter { $0.state == .queued }.count }

    @discardableResult public func add(_ urls: [URL], chapterIDs: Set<String>? = nil) -> Int {
        guard !isRunning else { return 0 }
        var pending = Set(jobs.filter { [.queued, .running].contains($0.state) }.map { $0.source.resolvingSymlinksInPath().standardizedFileURL })
        var added = 0
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == "epub" {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            if pending.insert(canonical).inserted {
                jobs.append(AudiobookJob(source: url, chapterIDs: chapterIDs)); added += 1
            }
        }
        if added > 0 { summary = "\(queuedCount) " + (queuedCount == 1 ? "EPUB ready to convert." : "EPUBs ready to convert.") }
        return added
    }

    public func remove(_ id: UUID) {
        guard !isRunning else { return }
        jobs.removeAll { $0.id == id }
    }

    public func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard !isRunning, abs(offset) == 1, let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        return jobs.indices.contains(index + offset)
    }

    public func move(_ id: UUID, by offset: Int) {
        guard canMove(id, by: offset), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.swapAt(index, index + offset)
    }

    public func replaceWithCombined(_ ids: Set<UUID>, source: URL) {
        guard !isRunning, ids.count >= 2,
              jobs.filter({ ids.contains($0.id) && $0.state == .queued }).count == ids.count,
              let first = jobs.firstIndex(where: { ids.contains($0.id) }) else { return }
        jobs.removeAll { ids.contains($0.id) }
        jobs.insert(AudiobookJob(source: source), at: first)
        summary = "Combined EPUB added to the queue."
    }

    public func updateMetadata(_ id: UUID, book: EPUBBook) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].title = book.title; jobs[index].author = book.author
    }

    public func clearFinished() {
        guard !isRunning else { return }
        jobs.removeAll { $0.state == .done }
    }

    public func retry(_ id: UUID) {
        guard !isRunning, let index = jobs.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(jobs[index].state) else { return }
        jobs[index].state = .queued; jobs[index].progress = 0
        jobs[index].message = "Waiting to retry."; jobs[index].output = nil
    }

    public func start(settings: BatchNarrationSettings, folder: URL) throws {
        guard !isRunning, queuedCount > 0 else { return }
        try settings.api?.validate()
        guard (settings.api != nil || !settings.voice.isEmpty), SpeechRate.allowedRange.contains(settings.wordsPerMinute), [64, 96, 128, 192].contains(settings.bitrate) else {
            throw AudiobookError.conversion("Choose a voice, valid speaking speed, and MP3 quality before starting the queue.")
        }
        guard folder.isFileURL else { throw AudiobookError.conversion("Choose a local output folder.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        batchIDs = jobs.filter { $0.state == .queued }.map(\.id)
        batchFinished = 0; batchProgress = 0; pauseRequested = false; isRunning = true
        summary = "Starting \(batchIDs.count) " + (batchIDs.count == 1 ? "audiobook…" : "audiobooks…")
        task = Task { [self] in
            // Retain the activity between books, not just during individual exports.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Creating queued audiobooks")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            for id in batchIDs {
                if pauseRequested { break }
                guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
                jobs[index].state = .running; jobs[index].message = "Reading EPUB…"
                summary = "Converting \(batchFinished + 1) of \(batchIDs.count): \(jobs[index].title)"
                let source = jobs[index].source
                let selectedIDs = jobs[index].chapterIDs
                let processRunner = ProcessRunner()
                runner = processRunner
                do {
                    let book = try await reader(source)
                    try Task.checkCancellation()
                    jobs[index].title = book.title; jobs[index].author = book.author
                    activeBook = (id, book)
                    let chapterIDs = selectedIDs ?? Set(book.chapters.filter(\.includedByDefault).map(\.id))
                    let options = ExportOptions(voice: settings.voice, wordsPerMinute: settings.wordsPerMinute,
                        bitrate: settings.bitrate, mode: settings.mode, chapterIDs: chapterIDs, ffmpeg: settings.ffmpeg, api: settings.api)
                    let destination = Self.uniqueDestination(title: book.title, folder: folder, mode: settings.mode)
                    let result = try await exporter(book, options, destination, processRunner) { [weak self] update in
                        Task { @MainActor [weak self] in self?.receive(update, id: id) }
                    }
                    jobs[index].output = result; jobs[index].state = .done
                    jobs[index].progress = 1; jobs[index].message = "Audiobook ready."
                } catch is CancellationError {
                    jobs[index].state = .cancelled; jobs[index].progress = 0
                    jobs[index].message = "Cancelled. Retry to convert this EPUB again."
                } catch {
                    jobs[index].state = .failed; jobs[index].progress = 0
                    jobs[index].message = error.localizedDescription
                }
                runner = nil
                batchFinished += 1
                batchProgress = Double(batchFinished) / Double(batchIDs.count)
            }
            let completed = jobs.filter { batchIDs.contains($0.id) && $0.state == .done }.count
            let failed = jobs.filter { batchIDs.contains($0.id) && $0.state == .failed }.count
            if pauseRequested {
                summary = "Queue paused. \(completed) ready; \(queuedCount) waiting."
            } else {
                summary = "\(completed) " + (completed == 1 ? "audiobook ready" : "audiobooks ready") + (failed > 0 ? "; \(failed) failed. Select a failed row to retry." : ".")
            }
            isRunning = false; task = nil
        }
    }

    private func receive(_ update: ExportProgress, id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].progress = update.fraction; jobs[index].message = update.message
        batchProgress = (Double(batchFinished) + update.fraction) / Double(max(1, batchIDs.count))
        summary = "Converting \(batchFinished + 1) of \(batchIDs.count): \(jobs[index].title)"
    }

    public func cancelAndPause() {
        guard isRunning else { return }
        pauseRequested = true; summary = "Cancelling the current audiobook…"
        runner?.cancel(); task?.cancel()
    }

    public func waitUntilFinished() async { await task?.value }
    public func shutdown() async { cancelAndPause(); await task?.value }

    public static func uniqueDestination(title: String, folder: URL, mode: ExportMode) -> URL {
        let name = FileNames.safe(title)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? name : "\(name) (\(suffix))"
            let url = folder.appendingPathComponent(mode == .single ? stem + ".mp3" : stem, isDirectory: mode == .chapters)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            suffix += 1
        }
    }
}
