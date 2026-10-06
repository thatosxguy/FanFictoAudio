import Foundation
import AudiobookCore

@main
struct EPUBAudioCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["voices"] {
                for voice in try await SpeechTools.voices() { print(voice.label) }
                return
            }
            guard args.count >= 2 else {
                print("Usage: epub-audio inspect BOOK.epub\n       epub-audio export BOOK.epub OUTPUT [--voice NAME] [--rate 175] [--bitrate 128] [--chapters] [--ffmpeg PATH]\n       epub-audio combine TITLE OUTPUT.epub BOOK1.epub BOOK2.epub ...\n       epub-audio benchmark-read BOOK.epub\n       epub-audio voices")
                return
            }
            if args[0] == "combine", args.count >= 5 {
                let result = try EPUBMerger.combine(args.dropFirst(3).map { URL(fileURLWithPath: $0) }, title: args[1], destination: URL(fileURLWithPath: args[2]))
                print("\(result.title): \(result.chapters.count) sections\n\(result.source.path)")
                return
            }
            if args[0] == "benchmark-read" {
                let source = URL(fileURLWithPath: args[1])
                let clock = ContinuousClock()
                let iterations = 20
                let start = clock.now
                for _ in 0..<iterations { _ = try EPUBReader.read(source) }
                let uncached = start.duration(to: clock.now)
                let library = EPUBLibrary()
                _ = try await library.read(source)
                let cachedStart = clock.now
                for _ in 0..<iterations { _ = try await library.read(source) }
                let cached = cachedStart.duration(to: clock.now)
                func milliseconds(_ duration: Duration) -> Double {
                    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                }
                let result: [String: Any] = ["iterations": iterations, "uncached_mean_ms": milliseconds(uncached) / Double(iterations), "cached_mean_ms": milliseconds(cached) / Double(iterations)]
                print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                return
            }
            let book = try EPUBReader.read(URL(fileURLWithPath: args[1]))
            if args[0] == "inspect" {
                print("\(book.title)\n\(book.author)\nLanguage: \(book.language)")
                for chapter in book.chapters { print("\(chapter.includedByDefault ? "✓" : "·") \(chapter.title) — \(chapter.wordCount) words") }
                for warning in book.warnings { print("Warning: \(warning)") }
                return
            }
            guard args[0] == "export", args.count >= 3 else { throw AudiobookError.conversion("Expected inspect or export; export requires a destination.") }
            func option(_ flag: String) throws -> String? {
                guard let index = args.firstIndex(of: flag) else { return nil }
                guard index + 1 < args.count else { throw AudiobookError.conversion("Missing value for \(flag).") }
                return args[index + 1]
            }
            let voice = SystemVoice.preferredName(in: try await SpeechTools.voices())
            let ffmpeg = try option("--ffmpeg").map { URL(fileURLWithPath: $0) } ?? SpeechTools.findFFmpeg()
            guard let ffmpeg else { throw AudiobookError.conversion("FFmpeg is missing. Install it or pass --ffmpeg PATH.") }
            let options = try ExportOptions(voice: option("--voice") ?? voice,
                wordsPerMinute: Int(option("--rate") ?? "175") ?? 175,
                bitrate: Int(option("--bitrate") ?? "128") ?? 128,
                mode: args.contains("--chapters") ? .chapters : .single,
                chapterIDs: Set(book.chapters.filter(\.includedByDefault).map(\.id)), ffmpeg: ffmpeg)
            let result = try await AudiobookExporter.export(book: book, options: options, destination: URL(fileURLWithPath: args[2])) { status in
                print("\(Int(status.fraction * 100))% \(status.message)")
            }
            print(result.path)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
