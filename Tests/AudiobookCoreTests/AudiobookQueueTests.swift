import Foundation
import Testing
@testable import AudiobookCore

@MainActor
struct AudiobookQueueTests {
    @Test func persistsOrderSelectionSectionsAndSecretFreeSettings() throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sources = try fixtures(root, names: ["one.epub", "two.epub"])
        let storage = root.appendingPathComponent("queue.json")
        let queue = AudiobookQueue(storage: storage)
        queue.add(sources)
        let first = queue.jobs[0].id
        queue.move(first, by: 1)
        let api = APINarration(provider: .openAI, model: "test", voice: "marin", apiKey: "never-store-this-key")
        queue.updateSettings(first, chapterIDs: ["extra"], narration: NarrationPreset(voice: "", wordsPerMinute: 175, bitrate: 192, mode: .m4b, api: api))
        queue.rememberSelection(first)
        let restored = AudiobookQueue(storage: storage)
        #expect(restored.jobs.map(\.id) == queue.jobs.map(\.id))
        #expect(restored.jobs.map(\.source) == [sources[1], sources[0]])
        #expect(restored.jobs[1].chapterIDs == ["extra"])
        #expect(restored.jobs[1].narration?.mode == .m4b)
        #expect(restored.selectedID == first)
        #expect(!String(decoding: try Data(contentsOf: storage), as: UTF8.self).contains("never-store-this-key"))
        // Simulate a crash while a job is running; it must become resumable.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as? [String: Any])
        var jobs = try #require(json["jobs"] as? [[String: Any]])
        jobs[0]["state"] = "Converting"; json["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: json).write(to: storage)
        #expect(AudiobookQueue(storage: storage).jobs[0].state == .queued)
    }

    @Test func corruptSavedQueueIsPreservedAndReported() throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("queue.json")
        let original = Data("invalid saved queue".utf8); try original.write(to: storage)
        let queue = AudiobookQueue(storage: storage)
        #expect(queue.persistenceError != nil)
        queue.add([root.appendingPathComponent("new.epub")])
        #expect(try Data(contentsOf: storage) == original)
        #expect(throws: (any Error).self) { try queue.start(settings: settings(), folder: root) }
    }

    @Test func budgetStopPausesRemainingJobs() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sources = try fixtures(root, names: ["one.epub", "two.epub"])
        let queue = AudiobookQueue(reader: Self.readFixture, exporter: { _, _, _, _, _ in
            throw APIUsageError.budgetReached("Budget reached")
        })
        queue.add(sources)
        try queue.start(settings: settings(), folder: root)
        await queue.waitUntilFinished()
        #expect(queue.jobs.map(\.state) == [.failed, .queued])
        #expect(queue.summary.contains("paused"))
    }

    @Test func processesBooksSequentiallyContinuesAfterFailureAndPreservesOutputs() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try fixtures(root, names: ["one.epub", "broken.epub", "two.epub"])
        try "broken".write(to: sources[1], atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let existing = output.appendingPathComponent("Shared Title.mp3")
        try Data("keep me".utf8).write(to: existing)
        let recorder = QueueRecorder()
        let queue = AudiobookQueue(reader: Self.readFixture, exporter: { book, options, destination, runner, progress in
            try await recorder.export(book, options, destination, runner, progress)
        })
        #expect(queue.add(sources) == 3)
        try queue.start(settings: settings(), folder: output)
        await queue.waitUntilFinished()
        #expect(queue.jobs.map(\.state) == [.done, .failed, .done])
        #expect(queue.jobs[0].output?.lastPathComponent == "Shared Title (2).mp3")
        #expect(queue.jobs[2].output?.lastPathComponent == "Shared Title (3).mp3")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
        let calls = await recorder.calls
        #expect(calls.map(\.voice) == ["Test Voice", "Test Voice"])
        #expect(calls.allSatisfy { $0.wordsPerMinute == 200 && $0.bitrate == 96 && $0.chapterIDs == ["one"] })
        #expect(await recorder.maximumActive == 1)
        #expect(queue.summary.contains("1 failed"))
        // Fix the failed source and retry only that job with new settings.
        try "fixed".write(to: sources[1], atomically: true, encoding: .utf8)
        queue.retry(queue.jobs[1].id)
        queue.updateSettings(queue.jobs[1].id, chapterIDs: ["one"], narration: nil)
        try queue.start(settings: settings(voice: "Retry Voice"), folder: output)
        await queue.waitUntilFinished()
        #expect(queue.jobs.allSatisfy { $0.state == .done })
        #expect(await recorder.calls.last?.voice == "Retry Voice")
        #expect(queue.jobs[1].output?.lastPathComponent == "Shared Title (4).mp3")
    }

    @Test func supportsChapterFoldersAndExplicitSectionSelections() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixtures(root, names: ["one.epub"])[0]
        let recorder = QueueRecorder()
        let queue = AudiobookQueue(reader: Self.readFixture, exporter: { book, options, destination, runner, progress in
            try await recorder.export(book, options, destination, runner, progress)
        })
        queue.add([source], chapterIDs: ["extra"])
        try queue.start(settings: settings(mode: .chapters), folder: root)
        await queue.waitUntilFinished()
        #expect(queue.jobs[0].state == .done)
        #expect(queue.jobs[0].output?.lastPathComponent == "Shared Title")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Shared Title/001.mp3").path))
        #expect(await recorder.calls[0].chapterIDs == ["extra"])
    }

    @Test func cancellationPausesRemainingBooksAndCanResume() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try fixtures(root, names: ["one.epub", "two.epub"])
        let recorder = QueueRecorder(delayFirst: true)
        let queue = AudiobookQueue(reader: Self.readFixture, exporter: { book, options, destination, runner, progress in
            try await recorder.export(book, options, destination, runner, progress)
        })
        queue.add(sources)
        try queue.start(settings: settings(), folder: root)
        for _ in 0..<100 {
            if await recorder.active > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorder.active == 1)
        queue.cancelAndPause()
        await queue.waitUntilFinished()
        #expect(queue.jobs.map(\.state) == [.cancelled, .queued])
        #expect(queue.summary.contains("paused"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("partial.tmp").path))
        try queue.start(settings: settings(), folder: root)
        await queue.waitUntilFinished()
        #expect(queue.jobs.map(\.state) == [.cancelled, .done])
        #expect(queue.queuedCount == 0)
    }

    @Test func deduplicatesPendingEPUBsAndRejectsInvalidSettings() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixtures(root, names: ["one.epub"])[0]
        let alias = root.appendingPathComponent("alias.epub")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let queue = AudiobookQueue()
        #expect(queue.add([source, alias, source, root.appendingPathComponent("other.txt")]) == 1)
        #expect(throws: (any Error).self) { try queue.start(settings: settings(voice: ""), folder: root) }
        #expect(!queue.isRunning)
        queue.remove(queue.jobs[0].id)
        #expect(queue.jobs.isEmpty)
    }

    @Test func movingChangesExecutionOrderAndCombiningReplacesOnlySelectedWaitingJobs() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sources = try fixtures(root, names: ["one.epub", "two.epub", "three.epub"])
        let recorder = QueueRecorder()
        let queue = AudiobookQueue(reader: Self.readFixture, exporter: { book, options, destination, runner, progress in
            try await recorder.export(book, options, destination, runner, progress)
        })
        queue.add(sources)
        let first = queue.jobs[0].id
        #expect(!queue.canMove(first, by: -1))
        queue.move(first, by: 1)
        #expect(queue.jobs.map(\.source) == [sources[1], sources[0], sources[2]])
        try queue.start(settings: settings(), folder: root)
        queue.move(first, by: -1)
        #expect(queue.jobs.map(\.source) == [sources[1], sources[0], sources[2]])
        await queue.waitUntilFinished()
        #expect(await recorder.sources == [sources[1], sources[0], sources[2]])
        #expect(queue.activeBook?.id == queue.jobs.last?.id)
        queue.add(sources)
        let waiting = queue.jobs.filter { $0.state == .queued }
        let combined = root.appendingPathComponent("combined.epub")
        queue.replaceWithCombined([waiting[0].id, waiting[2].id], source: combined)
        #expect(queue.jobs.filter { $0.state == .queued }.map(\.source) == [combined, sources[1]])
        #expect(queue.jobs.filter { $0.state == .done }.count == 3)
    }

    private func settings(voice: String = "Test Voice", mode: ExportMode = .single) -> BatchNarrationSettings {
        BatchNarrationSettings(voice: voice, wordsPerMinute: 200, bitrate: 96, mode: mode, ffmpeg: URL(fileURLWithPath: "/usr/bin/true"))
    }
    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audiobook-queue-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func fixtures(_ root: URL, names: [String]) throws -> [URL] {
        try names.map { name in
            let url = root.appendingPathComponent(name)
            try "original".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
    nonisolated private static func readFixture(_ url: URL) async throws -> EPUBBook {
        if try String(contentsOf: url, encoding: .utf8) == "broken" { throw AudiobookError.invalidEPUB("Broken EPUB") }
        return EPUBBook(title: "Shared Title", author: "Author", language: "en", chapters: [
            BookChapter(id: "one", title: "One", text: "Some words."),
            BookChapter(id: "extra", title: "Extra", text: "Extra words.", includedByDefault: false)
        ], source: url)
    }
}

private actor QueueRecorder {
    var calls: [ExportOptions] = []
    var sources: [URL] = []
    var active = 0
    var maximumActive = 0
    private var delayFirst: Bool
    init(delayFirst: Bool = false) { self.delayFirst = delayFirst }
    func export(_ book: EPUBBook, _ options: ExportOptions, _ destination: URL,
                _ runner: ProcessRunner, _ progress: @Sendable (ExportProgress) -> Void) async throws -> URL {
        sources.append(book.source)
        calls.append(options); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        progress(ExportProgress(0.2, "Working…"))
        if delayFirst {
            delayFirst = false
            let partial = destination.deletingLastPathComponent().appendingPathComponent("partial.tmp")
            try Data("temporary".utf8).write(to: partial)
            defer { try? FileManager.default.removeItem(at: partial) }
            try await Task.sleep(for: .seconds(30))
        } else { try await Task.sleep(for: .milliseconds(25)) }
        try runner.checkCancellation()
        if options.mode == .chapters {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("audio".utf8).write(to: destination.appendingPathComponent("001.mp3"))
        } else { try Data("audio".utf8).write(to: destination, options: .withoutOverwriting) }
        return destination
    }
}
