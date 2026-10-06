import Foundation
import Testing
@testable import DownloadCore

struct DownloadTests {
    @Test func validatesStoryURLsAndPreservesChapterRanges() throws {
        #expect(try StoryLinks.parse("# comment\nhttps://example.com/story[1-5]\nhttps://example.com/story[1-5]\nhttp://other.example/2") == ["https://example.com/story[1-5]", "http://other.example/2"])
        for text in ["", "file:///etc/passwd", "https://", "https://example.com/1 https://example.com/2"] {
            #expect(throws: (any Error).self) { try StoryLinks.parse(text) }
        }
    }

    @Test func publicationReceivesAcknowledgementAndRejectsLateCancellation() async throws {
        let fixture = try MockHelper(mode: "success")
        defer { fixture.remove() }
        let runner = DownloadRunner()
        let result = try await runner.run(fixture.request, executable: fixture.python, arguments: fixture.arguments) { event in
            if event.finalizing == true { #expect(runner.cancel() == false) }
        }
        #expect(result.path == "/tmp/A Story 女.epub")
        #expect(result.metadata?["title"] == "A Story 女")
        #expect(try fixture.stagingFolders().isEmpty)
    }

    @Test func cancellationStopsDownloadAndCleansStaging() async throws {
        let fixture = try MockHelper(mode: "slow")
        defer { fixture.remove() }
        let runner = DownloadRunner()
        let task = Task { try await runner.run(fixture.request, executable: fixture.python, arguments: fixture.arguments) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(runner.cancel())
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(try fixture.stagingFolders().isEmpty)
    }

    @Test func helperErrorsAndTruncatedProtocolAreFailures() async throws {
        for mode in ["error", "truncated", "missing"] {
            let fixture = try MockHelper(mode: mode)
            defer { fixture.remove() }
            do {
                _ = try await DownloadRunner().run(fixture.request, executable: fixture.python, arguments: fixture.arguments) { _ in }
                Issue.record("Expected failure for \(mode)")
            } catch { #expect(!error.localizedDescription.isEmpty) }
            #expect(try fixture.stagingFolders().isEmpty)
        }
    }

    @Test func preCancelledDownloadCannotCreateAnEPUB() async throws {
        let fixture = try MockHelper(mode: "success")
        defer { fixture.remove() }
        let runner = DownloadRunner()
        runner.cancel()
        do {
            _ = try await runner.run(fixture.request, executable: fixture.python, arguments: fixture.arguments) { _ in }
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(try fixture.stagingFolders().isEmpty)
    }
}

private struct MockHelper {
    let directory: URL
    let script: URL
    let mode: String
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    var arguments: [String] { [script.path, mode] }
    var request: DownloadRequest { DownloadRequest(source: "https://example.com/story", output: directory.path) }
    init(mode: String) throws {
        self.mode = mode
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        script = directory.appendingPathComponent("helper.py")
        try """
        import json, sys, time
        def emit(value):
            print(json.dumps(value, ensure_ascii=False), flush=True)
        mode = sys.argv[1]
        if mode == 'slow':
            time.sleep(30)
        elif mode == 'error':
            emit({'type': 'error', 'message': 'A chapter failed; book discarded.'})
            sys.exit(1)
        elif mode == 'truncated':
            print('{"type": "result"', end='', flush=True)
        elif mode == 'success':
            emit({'type': 'progress', 'finalizing': True, 'percent': 99})
            if sys.stdin.readline().strip() != 'commit': sys.exit(2)
            emit({'type': 'result', 'status': 'done', 'path': '/tmp/A Story 女.epub', 'metadata': {'title': 'A Story 女'}})
        """.write(to: script, atomically: true, encoding: .utf8)
    }
    func stagingFolders() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".fff-work-") }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
