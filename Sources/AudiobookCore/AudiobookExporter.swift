import Foundation
import AVFAudio

public enum AudiobookExporter {
    public static func export(book: EPUBBook, options: ExportOptions, destination: URL,
                              runner: ProcessRunner = ProcessRunner(),
                              progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) async throws -> URL {
        let chapters = book.chapters.filter { options.chapterIDs.contains($0.id) }
        guard !chapters.isEmpty else { throw AudiobookError.conversion("Select at least one chapter to export.") }
        guard SpeechRate.allowedRange.contains(options.wordsPerMinute), [64, 96, 128, 192].contains(options.bitrate), !options.voice.isEmpty else {
            throw AudiobookError.conversion("Invalid voice, speaking speed, or audio quality.")
        }
        guard destination.standardizedFileURL != book.source.standardizedFileURL else {
            throw AudiobookError.conversion("The export destination cannot be the original EPUB.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AudiobookError.conversion("That destination already exists. Choose a new name to preserve the existing file.")
        }
        progress(ExportProgress(0, "Checking MP3 encoder…"))
        try await SpeechTools.verifyFFmpeg(options.ffmpeg, runner: runner)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Creating an audiobook")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".epub-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let work = stage.appendingPathComponent("work", isDirectory: true)
        let result = stage.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        var chapterAudio: [URL] = []
        let totalCharacters = max(1, chapters.reduce(0) { $0 + $1.text.count })
        var completedCharacters = 0
        for (chapterIndex, chapter) in chapters.enumerated() {
            try runner.checkCancellation()
            let chunks = speechChunks(chapter.text)
            var parts: [URL] = []
            for (chunkIndex, chunk) in chunks.enumerated() {
                try runner.checkCancellation()
                let fraction = Double(completedCharacters) / Double(totalCharacters) * 0.94
                progress(ExportProgress(fraction, "Narrating \(chapterIndex + 1) of \(chapters.count): \(chapter.title) · passage \(chunkIndex + 1) of \(chunks.count)"))
                let text = work.appendingPathComponent("passage.txt")
                let pcm = work.appendingPathComponent("passage.aiff")
                let mp3 = work.appendingPathComponent("part-\(chunkIndex).mp3")
                try chunk.write(to: text, atomically: true, encoding: .utf8)
                _ = try await runner.run(SpeechTools.say, arguments: ["-v", options.voice, "-r", String(options.wordsPerMinute),
                    "-f", text.path, "-o", pcm.path, "--data-format=BEI16@22050"])
                try runner.checkCancellation()
                try validateSpeech(pcm, voice: options.voice)
                var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", pcm.path,
                                 "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "22050", "-c:a", "libmp3lame",
                                 "-b:a", "\(options.bitrate)k"]
                if chunkIndex == chunks.count - 1 { arguments += ["-af", "apad=pad_dur=0.7"] }
                arguments += ["-map_metadata", "-1", mp3.path]
                _ = try await runner.run(options.ffmpeg, arguments: arguments)
                try FileManager.default.removeItem(at: pcm)
                parts.append(mp3)
                completedCharacters += chunk.count
            }
            let chapterURL = result.appendingPathComponent(String(format: "%03d", chapterIndex + 1) + " - " + FileNames.safe(chapter.title) + ".mp3")
            try await concatenate(parts, output: chapterURL, metadata: ["title=\(chapter.title)", "artist=\(book.author)",
                "album=\(book.title)", "track=\(chapterIndex + 1)/\(chapters.count)", "genre=Audiobook"],
                work: work, ffmpeg: options.ffmpeg, runner: runner)
            for part in parts { try FileManager.default.removeItem(at: part) }
            chapterAudio.append(chapterURL)
        }
        try runner.checkCancellation()
        progress(ExportProgress(0.96, "Finishing MP3 export…"))
        if options.mode == .single {
            let complete = stage.appendingPathComponent("audiobook.mp3")
            try await concatenate(chapterAudio, output: complete, metadata: ["title=\(book.title)", "artist=\(book.author)",
                "album=\(book.title)", "genre=Audiobook"], work: work, ffmpeg: options.ffmpeg, runner: runner)
            try runner.checkCancellation()
            try FileManager.default.moveItem(at: complete, to: destination)
        } else {
            try runner.checkCancellation()
            try FileManager.default.moveItem(at: result, to: destination)
        }
        progress(ExportProgress(1, "Your audiobook is ready."))
        return destination
    }

    static func validateSpeech(_ url: URL, voice: String) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                if UnsafeBufferPointer(start: samples[channel], count: Int(buffer.frameLength)).contains(where: { abs($0) > 0.00001 }) { return }
            }
        }
        throw AudiobookError.conversion("macOS produced no audible speech for \(voice). Try another installed voice, or run the app directly outside a restricted command environment.")
    }

    private static func concatenate(_ inputs: [URL], output: URL, metadata: [String], work: URL, ffmpeg: URL, runner: ProcessRunner) async throws {
        let list = work.appendingPathComponent("join.txt")
        let content = inputs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n") + "\n"
        try content.write(to: list, atomically: true, encoding: .utf8)
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-f", "concat", "-safe", "0", "-i", list.path,
                         "-map", "0:a:0", "-c:a", "copy", "-map_metadata", "-1", "-id3v2_version", "3"]
        for item in metadata { arguments += ["-metadata", item] }
        arguments.append(output.path)
        _ = try await runner.run(ffmpeg, arguments: arguments)
        let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw AudiobookError.conversion("The MP3 encoder produced an empty file.") }
    }

    // Bound PCM disk use and avoid speech engine limits on very long chapters.
    // Prefer paragraph and sentence boundaries; retain every character in order.
    static func speechChunks(_ text: String, limit: Int = 6000) -> [String] {
        var remaining = text[...]
        var chunks: [String] = []
        while !remaining.isEmpty {
            if remaining.count <= limit { chunks.append(String(remaining)); break }
            let cutoff = remaining.index(remaining.startIndex, offsetBy: limit)
            let prefix = remaining[..<cutoff]
            let floor = prefix.index(prefix.startIndex, offsetBy: limit / 2)
            let tail = prefix[floor...]
            let split: String.Index
            if let range = tail.range(of: "\n\n", options: .backwards) { split = range.upperBound }
            else if let range = tail.range(of: #"[.!?][\s]+"#, options: [.regularExpression, .backwards]) { split = range.upperBound }
            else if let whitespace = tail.lastIndex(where: { $0.isWhitespace }) { split = remaining.index(after: whitespace) }
            else { split = cutoff }
            chunks.append(String(remaining[..<split]))
            remaining = remaining[split...]
        }
        return chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
