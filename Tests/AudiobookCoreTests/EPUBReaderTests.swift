import Testing
import Foundation
import AVFAudio
@testable import AudiobookCore

struct EPUBReaderTests {
    @Test func testReadsPackageLocationSpineOrderNavigationAndMetadata() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try EPUBReader.read(url)
        #expect((book.title) == ("A Small Book & a Big Adventure"))
        #expect((book.author) == ("Test Author"))
        #expect((book.language) == ("en-US"))
        #expect((book.chapters.map(\.title)) == (["Chapter One", "Chapter Two", "Contents"]))
        #expect((book.chapters.map(\.includedByDefault)) == ([true, true, false]))
        #expect(book.chapters[0].text.contains("Hello, brave world & friends."))
        #expect(!(book.chapters[0].text.contains("doNotRead")))
        #expect(!(book.chapters[0].text.contains("Hidden material")))
        #expect(!(book.chapters[0].text.contains("Page title")))
        #expect((book.chapters[1].text) == ("Second heading\n\nThe second chapter follows the first."))
        #expect(book.warnings.isEmpty)
    }

    @Test func testLegacyNCXAndRootPackageAreSupported() throws {
        let url = try fixture(rootPackage: true, legacy: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try EPUBReader.read(url)
        #expect((book.chapters[0].title) == ("Legacy One"))
        #expect((book.chapters[1].title) == ("Legacy Two"))
    }

    @Test func testTextSeparatesBlocksButKeepsInlineWords() throws {
        let doc = try XMLDocument(xmlString: "<body><p>A <em>small</em> book.</p><p>Next<br/>line.</p><script>bad</script><style>bad</style><svg><text>bad</text></svg><table><tr><td>one</td><td>two</td></tr></table></body>")
        let text = EPUBReader.readableText(doc.rootElement()!)
        #expect((text) == ("A small book.\n\nNext\n\nline.\n\none two"))
    }

    @Test func testSpeechControlSequencesBecomeLiteralText() throws {
        let doc = try XMLDocument(xmlString: "<body><p>[[rate 900]] Book text.</p></body>")
        #expect((EPUBReader.readableText(doc.rootElement()!)) == ("[ [rate 900] ] Book text."))
    }

    @Test func testPercentEncodedRelativeReferencesAndTraversal() throws {
        #expect((try EPUBReader.resolve("../Text/ch%201.xhtml#part", relativeTo: "OPS/nav/toc.xhtml")) == ("OPS/Text/ch 1.xhtml"))
        #expect((try EPUBReader.resolve("#part", relativeTo: "OPS/ch.xhtml")) == ("OPS/ch.xhtml"))
        #expect(throws: (any Error).self) { try EPUBReader.resolve("../../secret", relativeTo: "OPS/book.opf") }
        #expect(throws: (any Error).self) { try EPUBReader.resolve("https://example.com/chapter", relativeTo: "OPS/book.opf") }
        #expect(throws: (any Error).self) { try EPUBReader.resolve("%2Fetc/passwd", relativeTo: "OPS/book.opf") }
    }

    @Test func testDamagedArchiveAndChecksumAreRejected() throws {
        var archive = storedZIP([("test.txt", "Some prose")])
        archive[30 + "test.txt".utf8.count] ^= 1
        let url = try save(archive)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try ZIPArchive(url: url).read("test.txt") }
        let truncated = try save(Data(archive.prefix(20)))
        defer { try? FileManager.default.removeItem(at: truncated) }
        #expect(throws: (any Error).self) { try ZIPArchive(url: truncated) }
    }

    @Test func testDuplicateAndUnsafeZIPEntriesAreRejected() throws {
        for entries in [[("same", "a"), ("same", "b")], [("../escape", "a")]] {
            let url = try save(storedZIP(entries))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: (any Error).self) { try ZIPArchive(url: url) }
        }
    }

    @Test func testMissingSpineDocumentIsAnErrorRatherThanSilentOmission() throws {
        let url = try fixture(missingChapter: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try EPUBReader.read(url) }
    }

    @Test func testDRMTextIsRejectedButEncryptedFontsDoNotBlockText() throws {
        let encryptedBook = try fixture(encryptedURI: "OPS/Text/ch 1.xhtml")
        defer { try? FileManager.default.removeItem(at: encryptedBook) }
        #expect(throws: (any Error).self) { try EPUBReader.read(encryptedBook) }
        let fontsOnly = try fixture(encryptedURI: "OPS/Fonts/book.otf")
        defer { try? FileManager.default.removeItem(at: fontsOnly) }
        #expect((try EPUBReader.read(fontsOnly).chapters.count) == (3))
    }

    @Test func testExternalEntitiesAreNotRead() throws {
        let secret = try save(Data("EXTERNAL_SECRET_SHOULD_NOT_BE_READ".utf8))
        defer { try? FileManager.default.removeItem(at: secret) }
        let container = """
        <?xml version="1.0"?><!DOCTYPE container [<!ENTITY secret SYSTEM "\(secret.absoluteString)">]>
        <container><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles><extra>&secret;</extra></container>
        """
        let url = try fixture(containerOverride: container)
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try EPUBReader.read(url)
        #expect(!(book.chapters.map(\.text).joined().contains("EXTERNAL_SECRET")))
    }

    @Test func testSpeechChunkingPreservesLongTextAndBoundsChunks() {
        let text = String(repeating: "A complete sentence with words.\n\nAnother paragraph to narrate. ", count: 400)
        let chunks = AudiobookExporter.speechChunks(text)
        #expect((chunks.count) > (1))
        #expect((chunks.joined()) == (text))
        #expect(chunks.allSatisfy { $0.count <= 6000 && !$0.isEmpty })
        let unbroken = String(repeating: "字", count: 14_000)
        #expect((AudiobookExporter.speechChunks(unbroken).joined()) == (unbroken))
    }

    @Test func testVoiceListingSupportsEnhancedAndPremiumNames() {
        let voices = SystemVoice.parse("Ava (Premium)       en_US    # Hello\nArthur (Enhanced) en_GB # Hello\nAmélie fr_CA # Bonjour\nnot a voice")
        #expect((voices.count) == (3))
        #expect(voices.contains { $0.name == "Ava (Premium)" && $0.language == "en_US" })
    }

    @Test func testDuplicateVoiceListingAndModernSamanthaName() {
        let voices = SystemVoice.parse("Albert en_US # Hello\nSamantha (English (US)) en_US # Hello\nSamantha (English (US)) en_US # Hello\nSamantha (Enhanced) en_US # Hello")
        #expect(voices.count == 3)
        #expect(SystemVoice.preferredName(in: voices) == "Samantha (Enhanced)")
    }

    @Test func testEmptyOrSilentSpeechCannotBeReportedAsAnAudiobook() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        do { _ = try AVAudioFile(forWriting: url, settings: format.settings) }
        #expect(throws: (any Error).self) { try AudiobookExporter.validateSpeech(url, voice: "Test") }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            buffer.frameLength = 4096
            buffer.floatChannelData![0].initialize(repeating: 0, count: 4096)
            try file.write(from: buffer)
        }
        #expect(throws: (any Error).self) { try AudiobookExporter.validateSpeech(url, voice: "Test") }
    }

    @Test func testSafeFilenamesRemainUsableAndCannotAddDirectories() {
        #expect((FileNames.safe(" ../A/B: C\nD ")) == ("A B C D"))
        #expect((FileNames.safe("...")) == ("Audiobook"))
        #expect((FileNames.safe(String(repeating: "x", count: 200)).count) <= (100))
    }

    @Test func testPreCancelledRunnerDoesNotLaunchAProcess() async {
        let runner = ProcessRunner()
        runner.cancel()
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
            Issue.record("Cancelled runner should throw")
        } catch { #expect(error is CancellationError) }
    }

    @Test func testCancellationStopsAnActiveProcess() async throws {
        let runner = ProcessRunner()
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"]) }
        try await Task.sleep(for: .milliseconds(150))
        let start = Date()
        runner.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect((Date().timeIntervalSince(start)) < (3))
    }

    @Test func testExportNeverOverwritesAnExistingDestination() async throws {
        let source = try fixture()
        let destination = try save(Data("existing audio".utf8))
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let book = try EPUBReader.read(source)
        let options = ExportOptions(voice: "Samantha", wordsPerMinute: 175, bitrate: 128, mode: .single,
            chapterIDs: Set(book.chapters.map(\.id)), ffmpeg: URL(fileURLWithPath: "/usr/bin/false"))
        do {
            _ = try await AudiobookExporter.export(book: book, options: options, destination: destination)
            Issue.record("Expected existing destination rejection")
        } catch { #expect(error.localizedDescription.contains("already exists")) }
        #expect((try String(contentsOf: destination, encoding: .utf8)) == ("existing audio"))
    }

    private func fixture(rootPackage: Bool = false, legacy: Bool = false, missingChapter: Bool = false,
                         encryptedURI: String? = nil, containerOverride: String? = nil) throws -> URL {
        let prefix = rootPackage ? "" : "OPS/"
        let package = """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="\(legacy ? "2.0" : "3.0")">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>A Small Book &amp; a Big Adventure</dc:title><dc:creator>Test Author</dc:creator><dc:language>en-US</dc:language></metadata>
        <manifest>
        <item id="second" href="Text/second.xhtml" media-type="application/xhtml+xml"/>
        <item id="first" href="Text/ch%201.xhtml" media-type="application/xhtml+xml"/>
        \(legacy ? "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>" : "<item id=\"nav\" href=\"nav/toc.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        </manifest><spine toc="ncx"><itemref idref="first"/><itemref idref="second"/>\(legacy ? "" : "<itemref idref=\"nav\" linear=\"no\"/>")</spine></package>
        """
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><h1>Contents</h1><nav epub:type="toc"><ol><li><a href="../Text/ch%201.xhtml#start">Chapter One</a></li><li><a href="../Text/second.xhtml">Chapter Two</a></li></ol></nav></body></html>
        """
        let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint id="one"><navLabel><text>Legacy One</text></navLabel><content src="Text/ch%201.xhtml"/></navPoint><navPoint id="two"><navLabel><text>Legacy Two</text></navLabel><content src="Text/second.xhtml"/></navPoint></navMap></ncx>
        """
        var entries = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", containerOverride ?? "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"\(prefix)package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"),
            (prefix + "package.opf", package),
            (prefix + "Text/ch 1.xhtml", "<html><head><title>Page title</title><style>doNotRead</style></head><body><h1>First heading</h1><p>Hello, <em>brave</em> world &amp; friends.</p><script>doNotRead</script><p hidden=\"hidden\">Hidden material</p></body></html>"),
            (prefix + "nav/toc.xhtml", nav),
            (prefix + "toc.ncx", ncx)
        ]
        if !missingChapter { entries.append((prefix + "Text/second.xhtml", "<html><body><h1>Second heading</h1><p>The second chapter follows the first.</p></body></html>")) }
        if let encryptedURI { entries.append(("META-INF/encryption.xml", "<encryption><EncryptedData><CipherData><CipherReference URI=\"\(encryptedURI)\"/></CipherData></EncryptedData></encryption>")) }
        return try save(storedZIP(entries))
    }

    private func save(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("epub-test-\(UUID().uuidString).epub")
        try data.write(to: url)
        return url
    }
}

// Independent stored-ZIP fixture writer exercises the production directory reader.
private func storedZIP(_ entries: [(String, String)]) -> Data {
    var result = Data()
    var directory = Data()
    for (name, text) in entries {
        let bytes = Data(text.utf8)
        let nameBytes = Data(name.utf8)
        let offset = result.count
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        crc ^= 0xffffffff
        result.le32(0x04034b50); result.le16(20); result.le16(0x800); result.le16(0)
        result.le16(0); result.le16(0); result.le32(crc)
        result.le32(UInt32(bytes.count)); result.le32(UInt32(bytes.count)); result.le16(UInt16(nameBytes.count)); result.le16(0)
        result.append(nameBytes); result.append(bytes)
        directory.le32(0x02014b50); directory.le16(20); directory.le16(20); directory.le16(0x800); directory.le16(0)
        directory.le16(0); directory.le16(0); directory.le32(crc); directory.le32(UInt32(bytes.count)); directory.le32(UInt32(bytes.count))
        directory.le16(UInt16(nameBytes.count)); directory.le16(0); directory.le16(0); directory.le16(0); directory.le16(0)
        directory.le32(0); directory.le32(UInt32(offset)); directory.append(nameBytes)
    }
    let offset = result.count
    result.append(directory)
    result.le32(0x06054b50); result.le16(0); result.le16(0); result.le16(UInt16(entries.count)); result.le16(UInt16(entries.count))
    result.le32(UInt32(directory.count)); result.le32(UInt32(offset)); result.le16(0)
    return result
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 65535)); le16(UInt16(value >> 16)) }
}
