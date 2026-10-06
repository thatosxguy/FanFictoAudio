import Foundation
import AVFAudio
import Testing
@testable import AudiobookCore

struct SeriesAndAPITests {
    @Test func mergePreservesBookOrderResourcesLabelsAndOptionalSections() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture(root, name: "first.epub", title: "First & Book", text: "First story.")
        let second = try fixture(root, name: "second.epub", title: "Second Book", text: "Second story.")
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let destination = root.appendingPathComponent("series.epub")
        let combined = try EPUBMerger.combine([second, first], title: "Series & Friends", destination: destination)
        #expect(combined.title == "Series & Friends")
        #expect(combined.chapters.map(\.title) == ["Second Book", "Chapter Label", "Contents", "First & Book", "Chapter Label", "Contents"])
        #expect(combined.chapters.map(\.includedByDefault) == [true, true, false, true, true, false])
        #expect(combined.chapters[1].text.contains("Second story."))
        #expect(combined.chapters[4].text.contains("First story."))
        #expect(try [first, second].map { try Data(contentsOf: $0) } == originals)
        let archive = try ZIPArchive(url: destination)
        #expect(try archive.read("EPUB/books/1/OPS/style.css") == Data("p {color: blue}".utf8))
        #expect(try archive.read("EPUB/books/2/OPS/picture.png") == Data([1, 2, 3, 4]))
        #expect(try archive.read("EPUB/books/1/OPS/chapter.xhtml").contains(Data("href=\"style.css\"".utf8)))
        #expect(archive.entries["mimetype"]?.method == 0)
        #expect(archive.entries["EPUB/package.opf"]?.method == 8)
        let before = try Data(contentsOf: destination)
        #expect(throws: (any Error).self) { try EPUBMerger.combine([first, second], title: "Again", destination: destination) }
        #expect(try Data(contentsOf: destination) == before)
        let bad = root.appendingPathComponent("bad.epub"); try Data("bad".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try EPUBMerger.combine([first, bad], title: "Broken", destination: root.appendingPathComponent("broken.epub")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("broken.epub").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".series-") })
    }

    @Test func libraryInvalidatesWhenEPUBChanges() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, name: "book.epub", title: "Before", text: "Old content.")
        let library = EPUBLibrary()
        #expect(try await library.read(source).title == "Before")
        #expect(try await library.read(source).title == "Before")
        _ = try fixture(root, name: "book.epub", title: "After editing", text: "New longer content.")
        #expect(try await library.read(source).title == "After editing")
    }

    @Test func providerRequestsUseCorrectEndpointsFormatsAndCredentials() throws {
        let client = APISpeechClient()
        let open = try client.speechRequest(text: "A short sample.", settings: settings(.openAI))
        #expect(open.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(open.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let bodyData = try #require(open.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["input"] as? String == "A short sample.")
        #expect(body["response_format"] as? String == "wav")
        #expect(body["speed"] as? Double == 1)
        let eleven = try client.speechRequest(text: "Another sample.", settings: settings(.elevenLabs))
        #expect(eleven.url?.path == "/v1/text-to-speech/voice123")
        #expect(eleven.url?.query == "output_format=mp3_44100_128")
        #expect(eleven.value(forHTTPHeaderField: "xi-api-key") == "test-key")
        #expect(eleven.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(throws: (any Error).self) { try client.speechRequest(text: String(repeating: "x", count: 1501), settings: settings(.openAI)) }
        #expect(throws: (any Error).self) { try client.speechRequest(text: "sample", settings: APINarration(provider: .elevenLabs, model: "test", voice: "../bad", speed: 2, apiKey: "test")) }
    }

    @Test func APIErrorDoesNotExposeResponseAndDoesNotRetry() async throws {
        let recorder = RequestCount()
        let client = APISpeechClient(transport: { request in
            await recorder.increment()
            return (Data("test-key SECRET BOOK TEXT".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        })
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await client.synthesize(text: "sample", settings: settings(.openAI), destination: root.appendingPathComponent("audio.wav"))
            Issue.record("Expected API error")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 429"))
            #expect(!error.localizedDescription.contains("test-key"))
            #expect(!error.localizedDescription.contains("SECRET"))
        }
        #expect(await recorder.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func APITransportSupportsCancellationAndVoicePagination() async throws {
        let client = APISpeechClient(transport: { request in
            if request.url?.query?.contains("next_page_token") == true {
                return (Data("{\"voices\":[{\"voice_id\":\"b\",\"name\":\"Beta\"}],\"has_more\":false}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data("{\"voices\":[{\"voice_id\":\"a\",\"name\":\"Alpha\"}],\"has_more\":true,\"next_page_token\":\"page2\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await client.elevenLabsVoices(apiKey: "test").map(\.id) == ["a", "b"])
        let cancelClient = APISpeechClient(transport: { request in
            try await Task.sleep(for: .seconds(30))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await cancelClient.synthesize(text: "Sample", settings: settings(.openAI), destination: root.appendingPathComponent("audio.wav")) }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Wrong cancellation error") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func unicodeChunkingIsBoundedAndRetainsEveryScalar() {
        let text = String(repeating: "Hello 👩🏽‍💻. Another sentence.\n\n", count: 200)
        let chunks = AudiobookExporter.speechChunks(text, limit: 1500, utf8Limit: 2000)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.unicodeScalars.count <= 1500 })
        #expect(chunks.allSatisfy { $0.utf8.count <= 2000 })
        #expect(chunks.joined() == text)
    }

    @Test(arguments: [NarrationProvider.openAI, .elevenLabs]) func mockedAPIExportProducesAudibleMP3AndCleansStaging(provider: NarrationProvider) async throws {
        guard let ffmpeg = SpeechTools.findFFmpeg() else { return }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        buffer.frameLength = 2400
        for index in 0..<2400 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.12) * 0.3 }
        do { let file = try AVAudioFile(forWriting: wav, settings: format.settings); try file.write(from: buffer) }
        var audioSource = wav
        if provider == .elevenLabs {
            audioSource = root.appendingPathComponent("fixture.mp3")
            _ = try await ProcessRunner().run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", wav.path, "-c:a", "libmp3lame", audioSource.path])
        }
        let data = try Data(contentsOf: audioSource)
        let client = APISpeechClient(transport: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!)
        })
        let source = root.appendingPathComponent("original.epub")
        let book = EPUBBook(title: "Synthetic API Book", author: "Test", language: "en", chapters: [BookChapter(id: "1", title: "One", text: "First sample."), BookChapter(id: "2", title: "Two", text: "Second sample.")], source: source)
        let destination = root.appendingPathComponent("audio.mp3")
        let options = ExportOptions(voice: "", wordsPerMinute: 175, bitrate: 128, mode: .single, chapterIDs: ["1", "2"], ffmpeg: ffmpeg, api: settings(provider))
        _ = try await AudiobookExporter.export(book: book, options: options, destination: destination, apiClient: client)
        #expect((try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1000)
        let decoded = root.appendingPathComponent("decoded.wav")
        _ = try await ProcessRunner().run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", destination.path, "-c:a", "pcm_s16le", decoded.path])
        try AudiobookExporter.validateSpeech(decoded, voice: "Mock API")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".epub-audio-") })
    }

    private func settings(_ provider: NarrationProvider) -> APINarration {
        APINarration(provider: provider, model: provider == .openAI ? "gpt-4o-mini-tts" : "eleven_multilingual_v2", voice: provider == .openAI ? "marin" : "voice123", apiKey: "test-key")
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("series-api-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    private func fixture(_ root: URL, name: String, title: String, text: String) throws -> URL {
        let resources: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>"),
            ("OPS/book.opf", "<package><metadata><title>\(title.replacingOccurrences(of: "&", with: "&amp;"))</title><creator>Author</creator><language>en</language></metadata><manifest><item id=\"ch\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/><item id=\"img\" href=\"picture.png\" media-type=\"image/png\"/></manifest><spine><itemref idref=\"ch\"/><itemref idref=\"nav\"/></spine></package>"),
            ("OPS/chapter.xhtml", "<html><head><link href=\"style.css\" rel=\"stylesheet\"/></head><body><h1>Heading</h1><p>\(text)</p><img src=\"picture.png\"/></body></html>"),
            ("OPS/nav.xhtml", "<html><body><nav role=\"doc-toc\"><h1>Contents</h1><a href=\"chapter.xhtml\">Chapter Label</a></nav></body></html>"),
            ("OPS/style.css", "p {color: blue}")]
        let url = root.appendingPathComponent(name)
        try EPUBZIPWriter.encode(resources.map { ($0.0, Data($0.1.utf8)) } + [("OPS/picture.png", Data([1, 2, 3, 4]))]).write(to: url, options: .atomic)
        return url
    }
}
private actor RequestCount { var count = 0; func increment() { count += 1 } }
