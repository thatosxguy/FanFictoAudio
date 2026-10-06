import Foundation
import AVFAudio
import Testing
@testable import AudiobookCore

struct ImprovementsTests {
    @Test func readerAndSeriesPreserveEPUB2AndEPUB3CoverMetadata() async throws {
        let ffmpeg = try #require(SpeechTools.findFFmpeg())
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let coverURL = root.appendingPathComponent("cover.png")
        _ = try await ProcessRunner().run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=32x32", "-frames:v", "1", coverURL.path])
        let cover = try Data(contentsOf: coverURL)
        var sources: [URL] = []
        for legacy in [true, false] {
            let source = root.appendingPathComponent(legacy ? "legacy.epub" : "modern.epub")
            let metadata = legacy ? "<meta name=\"cover\" content=\"image\"/>" : ""
            let properties = legacy ? "" : " properties=\"cover-image\""
            let resources: [(String, Data)] = [
                ("mimetype", Data("application/epub+zip".utf8)),
                ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path=\"book.opf\"/></rootfiles></container>".utf8)),
                ("book.opf", Data("<package><metadata><title>Cover test</title>\(metadata)</metadata><manifest><item id=\"text\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"image\" href=\"cover.png\" media-type=\"image/png\"\(properties)/></manifest><spine><itemref idref=\"text\"/></spine></package>".utf8)),
                ("chapter.xhtml", Data("<html><body><p>Story text.</p></body></html>".utf8)), ("cover.png", cover)]
            try EPUBZIPWriter.encode(resources).write(to: source)
            #expect(try EPUBReader.read(source).cover == cover)
            sources.append(source)
        }
        let combined = try EPUBMerger.combine(sources, title: "Series", destination: root.appendingPathComponent("series.epub"))
        #expect(combined.cover == cover)
    }
    @Test func multilingualPreviewsFitActualRequestBounds() throws {
        for text in [String(repeating: "नमस्ते दुनिया ", count: 200), String(repeating: "👩🏽‍💻", count: 1000), String(repeating: "a\u{301}\u{302}", count: 1000)] {
            for provider in [NarrationProvider.openAI, .elevenLabs] {
                let preview = SpeechText.preview(text, provider: provider)
                #expect(!preview.isEmpty)
                #expect(text.hasPrefix(preview))
                _ = try APISpeechClient().speechRequest(text: preview, settings: api(provider))
            }
        }
    }

    @Test func cancellationEscalatesForChildIgnoringTermination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let runner = ProcessRunner(cancellationGrace: 0.15, commandTimeout: 10)
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; printf ready > '\(ready.path)'; exec /bin/sleep 30"]) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        let start = ContinuousClock.now
        runner.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func commandTimeoutIsBounded() async throws {
        let runner = ProcessRunner(cancellationGrace: 0.1, commandTimeout: 0.15)
        let start = ContinuousClock.now
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"])
            Issue.record("Expected timeout")
        } catch { #expect(error.localizedDescription.contains("timeout")) }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func usageIsPersistentAndBlocksBeforeDispatchIncludingFailedRequests() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("usage.json")
        let usage = APIUsageLedger(storage: storage)
        let calls = SpeechCalls()
        let client = APISpeechClient(transport: { request in
            await calls.increment()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        })
        let policy = APIBudget(characterLimit: 6, costLimit: 1, price: 1_000_000)
        // Use a character-only limit for a failed attempt, then test cost separately.
        do { try await client.synthesize(text: "hello", settings: api(), destination: root.appendingPathComponent("preview.wav"), usage: usage, budget: APIBudget(characterLimit: 6, price: 1)) } catch {}
        #expect(await calls.count == 1)
        #expect(await usage.snapshot().characters == 5)
        let restored = APIUsageLedger(storage: storage)
        do {
            try await client.synthesize(text: "hi", settings: api(), destination: root.appendingPathComponent("retry.wav"), usage: restored, budget: APIBudget(characterLimit: 6))
            Issue.record("Expected budget stop")
        } catch is APIUsageError {}
        #expect(await calls.count == 1)
        let costLedger = APIUsageLedger()
        do { try await costLedger.reserve(text: "hi", settings: api(), budget: policy); Issue.record("Expected cost stop") } catch is APIUsageError {}
        #expect(await costLedger.snapshot().requests == 0)
        #expect(!String(decoding: try Data(contentsOf: storage), as: UTF8.self).contains("test-key"))
    }

    @Test func corruptUsageCannotSilentlyResetBudget() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("usage.json")
        try Data("corrupt".utf8).write(to: storage)
        let ledger = APIUsageLedger(storage: storage)
        do { try await ledger.reserve(text: "sample", settings: api(), budget: nil); Issue.record("Expected recovery error") } catch {}
        #expect(try Data(contentsOf: storage) == Data("corrupt".utf8))
        try await ledger.reset()
        try await ledger.reserve(text: "sample", settings: api(), budget: nil)
        #expect(await ledger.snapshot().requests == 1)
    }

    @Test func checkpointRejectsChangedContentSettingsAndCorruptAudio() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audio.mp3"); try Data("synthetic".utf8).write(to: file)
        let book = book(root)
        let options = options(ffmpeg: URL(fileURLWithPath: "/usr/bin/true"), checkpoint: root.appendingPathComponent("checkpoints"))
        let cache = try ConversionCheckpoint(root: options.checkpoint!, book: book, options: options)
        try cache.commit("part-0-0.mp3", from: file, duration: 1)
        #expect(try cache.cached("part-0-0.mp3") != nil)
        let restored = try ConversionCheckpoint(root: options.checkpoint!, book: book, options: options)
        #expect(try restored.cached("part-0-0.mp3") != nil)
        let edited = EPUBBook(title: book.title, author: book.author, language: book.language,
            chapters: [BookChapter(id: "1", title: "One", text: "Edited story.")], source: book.source)
        #expect(try ConversionCheckpoint(root: options.checkpoint!, book: edited, options: options).cached("part-0-0.mp3") == nil)
        let changed = ExportOptions(voice: "Another voice", wordsPerMinute: 175, bitrate: 96, mode: .single, chapterIDs: ["1", "2"], ffmpeg: options.ffmpeg)
        #expect(try ConversionCheckpoint(root: options.checkpoint!, book: book, options: changed).cached("part-0-0.mp3") == nil)
        try Data("damaged".utf8).write(to: cache.directory.appendingPathComponent("part-0-0.mp3"))
        #expect(try restored.cached("part-0-0.mp3") == nil)
    }

    @Test func interruptedAPIExportResumesWithoutResendingCompletedPassage() async throws {
        let ffmpeg = try #require(SpeechTools.findFFmpeg())
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try audioFixture(root)
        let calls = SpeechCalls(failSecond: true)
        let client = APISpeechClient(transport: { request in
            if await calls.increment() == 2 { throw AudiobookError.conversion("Synthetic interruption") }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let checkpoint = root.appendingPathComponent("checkpoint")
        let options = options(ffmpeg: ffmpeg, checkpoint: checkpoint)
        let destination = root.appendingPathComponent("book.mp3")
        do {
            _ = try await AudiobookExporter.export(book: book(root), options: options, destination: destination, apiClient: client)
            Issue.record("Expected interruption")
        } catch { #expect(error.localizedDescription.contains("interruption")) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let retry = APISpeechClient(transport: { request in
            await calls.increment()
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await AudiobookExporter.export(book: book(root), options: options, destination: destination, apiClient: retry)
        #expect(await calls.count == 3) // One completed passage, one failed attempt, one retry.
        #expect(try FileManager.default.contentsOfDirectory(atPath: checkpoint.path).isEmpty)
    }

    @Test func M4BHasChapterMarkersCoverAndAudio() async throws {
        let ffmpeg = try #require(SpeechTools.findFFmpeg())
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("cover.png")
        _ = try await ProcessRunner().run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1", image.path])
        let data = try audioFixture(root)
        let client = APISpeechClient(transport: { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        let destination = root.appendingPathComponent("book.m4b")
        _ = try await AudiobookExporter.export(book: book(root, cover: Data(contentsOf: image)), options: options(ffmpeg: ffmpeg, mode: .m4b), destination: destination, apiClient: client)
        let info = try await probe(destination, ffmpeg: ffmpeg)
        let chapters = try #require(info["chapters"] as? [[String: Any]])
        #expect(chapters.count == 2)
        #expect((chapters[0]["tags"] as? [String: String])?["title"] == "One #=;")
        let start = Double(chapters[1]["start_time"] as? String ?? "0") ?? 0
        #expect(start > 0.7 && start < 1)
        let streams = try #require(info["streams"] as? [[String: Any]])
        #expect(streams.contains { $0["codec_name"] as? String == "aac" })
        #expect(streams.contains { ($0["disposition"] as? [String: Int])?["attached_pic"] == 1 })
    }

    @Test(arguments: [64, 96, 128, 192]) func exposedMP3BitratesAreHonored(bitrate: Int) async throws {
        let ffmpeg = try #require(SpeechTools.findFFmpeg())
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = try audioFixture(root)
        let client = APISpeechClient(transport: { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        let destination = root.appendingPathComponent("book.mp3")
        _ = try await AudiobookExporter.export(book: book(root), options: options(ffmpeg: ffmpeg, bitrate: bitrate), destination: destination, apiClient: client)
        let info = try await probe(destination, ffmpeg: ffmpeg)
        let stream = try #require((info["streams"] as? [[String: Any]])?.first)
        #expect(stream["sample_rate"] as? String == "44100")
        #expect(stream["bit_rate"] as? String == String(bitrate * 1000))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("improvements-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func api(_ provider: NarrationProvider = .openAI) -> APINarration {
        APINarration(provider: provider, model: "test-model", voice: "testVoice", apiKey: "test-key")
    }
    private func book(_ root: URL, cover: Data? = nil) -> EPUBBook {
        EPUBBook(title: "Synthetic #=; Book", author: "Test", language: "en", chapters: [
            BookChapter(id: "1", title: "One #=;", text: "First passage."), BookChapter(id: "2", title: "Two", text: "Second passage.")
        ], source: root.appendingPathComponent("book.epub"), cover: cover)
    }
    private func options(ffmpeg: URL, mode: ExportMode = .single, bitrate: Int = 192, checkpoint: URL? = nil) -> ExportOptions {
        ExportOptions(voice: "", wordsPerMinute: 175, bitrate: bitrate, mode: mode, chapterIDs: ["1", "2"], ffmpeg: ffmpeg, api: api(), checkpoint: checkpoint)
    }
    private func audioFixture(_ root: URL) throws -> Data {
        let url = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        buffer.frameLength = 2400
        for index in 0..<2400 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.12) * 0.3 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        return try Data(contentsOf: url)
    }
    private func probe(_ url: URL, ffmpeg: URL) async throws -> [String: Any] {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        #expect(FileManager.default.isExecutableFile(atPath: ffprobe.path), "FFprobe is required for metadata checks.")
        let result = try await ProcessRunner().run(ffprobe, arguments: ["-v", "error", "-show_streams", "-show_chapters", "-of", "json", url.path])
        return try #require(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
    }
}
private actor SpeechCalls {
    var count = 0
    init(failSecond: Bool = false) {}
    @discardableResult func increment() -> Int { count += 1; return count }
}
