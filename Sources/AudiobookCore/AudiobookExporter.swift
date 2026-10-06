import Foundation
import AVFAudio
import AudioToolbox

public enum AudiobookExporter {
    public static func export(book: EPUBBook, options: ExportOptions, destination: URL,
                              runner: ProcessRunner = ProcessRunner(),
                              apiClient: APISpeechClient = APISpeechClient(),
                              progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) async throws -> URL {
        let chapters = book.chapters.filter { options.chapterIDs.contains($0.id) }
        guard !chapters.isEmpty else { throw AudiobookError.conversion("Select at least one chapter to export.") }
        try options.api?.validate()
        guard SpeechRate.allowedRange.contains(options.wordsPerMinute), [64, 96, 128, 192].contains(options.bitrate), options.api != nil || !options.voice.isEmpty else {
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
        let sampleRate = options.api == nil ? "22050" : "44100"
        let totalCharacters = max(1, chapters.reduce(0) { $0 + $1.text.count })
        var completedCharacters = 0
        for (chapterIndex, chapter) in chapters.enumerated() {
            try runner.checkCancellation()
            let chunks = speechChunks(chapter.text, limit: options.api == nil ? 6000 : 1500, utf8Limit: options.api?.provider == .openAI ? 2000 : nil)
            var parts: [URL] = []
            for (chunkIndex, chunk) in chunks.enumerated() {
                try runner.checkCancellation()
                let fraction = Double(completedCharacters) / Double(totalCharacters) * 0.94
                progress(ExportProgress(fraction, "Narrating \(chapterIndex + 1) of \(chapters.count): \(chapter.title) · passage \(chunkIndex + 1) of \(chunks.count)"))
                let text = work.appendingPathComponent("passage.txt")
                var pcm = work.appendingPathComponent(options.api == nil ? "passage.aiff" : (options.api?.provider == .openAI ? "passage.wav" : "passage.mp3"))
                let mp3 = work.appendingPathComponent("part-\(chapterIndex)-\(chunkIndex).mp3")
                if let api = options.api {
                    try await apiClient.synthesize(text: chunk, settings: api, destination: pcm)
                    if api.provider == .elevenLabs {
                        // Validate decoded PCM; Core Audio cannot seek in every MP3 variant.
                        let decoded = work.appendingPathComponent("passage.wav")
                        _ = try await runner.run(options.ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", pcm.path, "-map", "0:a:0", "-c:a", "pcm_s16le", decoded.path])
                        try FileManager.default.removeItem(at: pcm)
                        pcm = decoded
                    }
                } else {
                    try chunk.write(to: text, atomically: true, encoding: .utf8)
                    _ = try await runner.run(SpeechTools.say, arguments: ["-v", options.voice, "-r", String(options.wordsPerMinute),
                        "-f", text.path, "-o", pcm.path, "--data-format=BEI16@22050"])
                }
                try runner.checkCancellation()
                try validateSpeech(pcm, voice: options.api?.provider.rawValue ?? options.voice)
                var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", pcm.path,
                                 "-map", "0:a:0", "-vn", "-ac", "1", "-ar", sampleRate, "-c:a", "libmp3lame",
                                 "-b:a", "\(options.bitrate)k"]
                if chunkIndex == chunks.count - 1 { arguments += ["-af", "apad=pad_dur=0.7"] }
                arguments += ["-map_metadata", "-1", mp3.path]
                _ = try await runner.run(options.ffmpeg, arguments: arguments)
                try FileManager.default.removeItem(at: pcm)
                parts.append(mp3)
                completedCharacters += chunk.count
            }
            if options.mode == .single {
                // Join all passages once; avoid a remux per chapter and its disk copy.
                chapterAudio += parts
            } else {
                let chapterURL = result.appendingPathComponent(String(format: "%03d", chapterIndex + 1) + " - " + FileNames.safe(chapter.title) + ".mp3")
                try await concatenate(parts, output: chapterURL, metadata: ["title=\(chapter.title)", "artist=\(book.author)",
                    "album=\(book.title)", "track=\(chapterIndex + 1)/\(chapters.count)", "genre=Audiobook"] + narrationMetadata(options),
                    work: work, ffmpeg: options.ffmpeg, runner: runner)
                for part in parts { try FileManager.default.removeItem(at: part) }
            }
        }
        try runner.checkCancellation()
        progress(ExportProgress(0.96, "Finishing MP3 export…"))
        if options.mode == .single {
            let complete = stage.appendingPathComponent("audiobook.mp3")
            try await concatenate(chapterAudio, output: complete, metadata: ["title=\(book.title)", "artist=\(book.author)",
                "album=\(book.title)", "genre=Audiobook"] + narrationMetadata(options), work: work, ffmpeg: options.ffmpeg, runner: runner)
            try runner.checkCancellation()
            try FileManager.default.moveItem(at: complete, to: destination)
        } else {
            try runner.checkCancellation()
            try FileManager.default.moveItem(at: result, to: destination)
        }
        progress(ExportProgress(1, "Your audiobook is ready."))
        return destination
    }

    private static func narrationMetadata(_ options: ExportOptions) -> [String] {
        options.api.map { ["comment=AI-generated narration using \($0.provider.rawValue)"] } ?? []
    }

    static func validateSpeech(_ url: URL, voice: String) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw AudiobookError.conversion("Speech validation requires decoded PCM audio.")
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                if UnsafeBufferPointer(start: samples[channel], count: Int(buffer.frameLength)).contains(where: { abs($0) > 0.00001 }) { return }
            }
        }
        throw AudiobookError.conversion("No audible speech was produced by \(voice). Try another voice or check the speech provider.")
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
    static func speechChunks(_ text: String, limit: Int = 6000, utf8Limit: Int? = nil) -> [String] {
        var remaining = text[...]
        var chunks: [String] = []
        while !remaining.isEmpty {
            var cutoff = remaining.unicodeScalars.index(remaining.unicodeScalars.startIndex, offsetBy: limit, limitedBy: remaining.unicodeScalars.endIndex) ?? remaining.endIndex
            if let utf8Limit {
                var bytes = 0
                for index in remaining.unicodeScalars.indices.prefix(limit) {
                    let value = remaining.unicodeScalars[index].value
                    bytes += value <= 0x7f ? 1 : value <= 0x7ff ? 2 : value <= 0xffff ? 3 : 4
                    if bytes > utf8Limit { cutoff = index; break }
                }
            }
            guard cutoff < remaining.endIndex else { chunks.append(String(remaining)); break }
            let prefix = remaining[..<cutoff]
            let floor = prefix.unicodeScalars.index(prefix.unicodeScalars.startIndex, offsetBy: prefix.unicodeScalars.count / 2)
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
