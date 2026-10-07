import Foundation
import AVFoundation
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
        progress(ExportProgress(0, "Checking audio encoder…"))
        try await SpeechTools.verifyFFmpeg(options.ffmpeg, runner: runner, mode: options.mode)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Creating an audiobook")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".epub-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let work = stage.appendingPathComponent("work", isDirectory: true)
        let result = stage.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        let checkpoint = try options.checkpoint.map { try ConversionCheckpoint(root: $0, book: book, options: options) }
        var chapterAudio: [URL] = []
        var chapterDurations: [Double] = []
        // MPEG-1 permits every exposed bitrate, including 192 kbps.
        let sampleRate = "44100"
        let partExtension = options.mode == .m4b ? "m4a" : "mp3"
        let totalCharacters = max(1, chapters.reduce(0) { $0 + $1.text.count })
        var completedCharacters = 0
        for (chapterIndex, chapter) in chapters.enumerated() {
            try runner.checkCancellation()
            let chunks = speechChunks(chapter.text, limit: options.api == nil ? 6000 : 1500, utf8Limit: options.api?.provider == .openAI ? 2000 : nil)
            var parts: [URL] = []
            var chapterDuration = 0.0
            for (chunkIndex, chunk) in chunks.enumerated() {
                try runner.checkCancellation()
                let fraction = Double(completedCharacters) / Double(totalCharacters) * 0.94
                progress(ExportProgress(fraction, "Narrating \(chapterIndex + 1) of \(chapters.count): \(chapter.title) · passage \(chunkIndex + 1) of \(chunks.count)"))
                let partName = "part-\(chapterIndex)-\(chunkIndex).\(partExtension)"
                if let cached = try checkpoint?.cached(partName), let checkpoint {
                    parts.append(checkpoint.directory.appendingPathComponent(partName))
                    chapterDuration += cached.duration; completedCharacters += chunk.count
                    progress(ExportProgress(Double(completedCharacters) / Double(totalCharacters) * 0.94, "Reusing completed passage \(chunkIndex + 1): \(chapter.title)"))
                    continue
                }
                let text = work.appendingPathComponent("passage.txt")
                var pcm = work.appendingPathComponent(options.api == nil ? "passage.aiff" : (options.api?.provider == .openAI ? "passage.wav" : "passage.mp3"))
                let mp3 = work.appendingPathComponent(partName)
                if let api = options.api {
                    try await apiClient.synthesize(text: chunk, settings: api, destination: pcm, usage: options.usage, budget: options.budget)
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
                        "-f", text.path, "-o", pcm.path, "--data-format=BEI16@44100"])
                }
                try runner.checkCancellation()
                try validateSpeech(pcm, voice: options.api?.provider.rawValue ?? options.voice)
                var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", pcm.path,
                                 "-map", "0:a:0", "-vn", "-ac", "1", "-ar", sampleRate, "-c:a", options.mode == .m4b ? "aac" : "libmp3lame",
                                 "-b:a", "\(options.bitrate)k"]
                if chunkIndex == chunks.count - 1 { arguments += ["-af", "apad=pad_dur=0.7"] }
                arguments += ["-map_metadata", "-1", mp3.path]
                _ = try await runner.run(options.ffmpeg, arguments: arguments)
                try FileManager.default.removeItem(at: pcm)
                let duration = try await audioDuration(mp3)
                chapterDuration += duration
                if let checkpoint {
                    try checkpoint.commit(partName, from: mp3, duration: duration)
                    try FileManager.default.removeItem(at: mp3)
                    parts.append(checkpoint.directory.appendingPathComponent(partName))
                } else { parts.append(mp3) }
                completedCharacters += chunk.count
            }
            chapterDurations.append(chapterDuration)
            if options.mode != .chapters {
                // Join all passages once; avoid a remux per chapter and its disk copy.
                chapterAudio += parts
            } else {
                let chapterURL = result.appendingPathComponent(String(format: "%03d", chapterIndex + 1) + " - " + FileNames.safe(chapter.title) + ".mp3")
                try await concatenate(parts, output: chapterURL, metadata: ["title=\(chapter.title)", "artist=\(book.author)",
                    "album=\(book.title)", "track=\(chapterIndex + 1)/\(chapters.count)", "genre=Audiobook"] + narrationMetadata(options),
                    work: work, ffmpeg: options.ffmpeg, runner: runner)
                // Checkpoints remain available until the complete output is published.
            }
        }
        try runner.checkCancellation()
        progress(ExportProgress(0.96, "Finishing audiobook export…"))
        if options.mode == .m4b {
            let complete = stage.appendingPathComponent("audiobook.m4b")
            try await createM4B(chapterAudio, chapters: chapters, durations: chapterDurations,
                book: book, options: options, output: complete, work: work, runner: runner)
            try runner.checkCancellation()
            try FileManager.default.moveItem(at: complete, to: destination)
        } else if options.mode == .single {
            let complete = stage.appendingPathComponent("audiobook.mp3")
            try await concatenate(chapterAudio, output: complete, metadata: ["title=\(book.title)", "artist=\(book.author)",
                "album=\(book.title)", "genre=Audiobook"] + narrationMetadata(options), work: work, ffmpeg: options.ffmpeg, runner: runner)
            try runner.checkCancellation()
            try FileManager.default.moveItem(at: complete, to: destination)
        } else {
            try runner.checkCancellation()
            try FileManager.default.moveItem(at: result, to: destination)
        }
        checkpoint?.discardCompleted()
        progress(ExportProgress(1, "Your audiobook is ready."))
        return destination
    }

    private static func audioDuration(_ url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AudiobookError.conversion("An encoded passage has no usable duration.") }
        return duration
    }

    private static func joinList(_ inputs: [URL], work: URL) throws -> URL {
        let list = work.appendingPathComponent("join.txt")
        let content = inputs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n") + "\n"
        try content.write(to: list, atomically: true, encoding: .utf8)
        return list
    }

    private static func createM4B(_ inputs: [URL], chapters: [BookChapter], durations: [Double],
                                  book: EPUBBook, options: ExportOptions, output: URL, work: URL, runner: ProcessRunner) async throws {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "=", with: "\\=")
                .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "#", with: "\\#")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        let list = try joinList(inputs, work: work)
        let metadata = work.appendingPathComponent("chapters.ffmetadata")
        var content = ";FFMETADATA1\ntitle=\(escape(book.title))\nartist=\(escape(book.author))\nalbum=\(escape(book.title))\ngenre=Audiobook\n"
        var position = 0.0
        for (chapter, duration) in zip(chapters, durations) {
            let start = Int((position * 1000).rounded()); position += duration
            content += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(start)\nEND=\(Int((position * 1000).rounded()))\ntitle=\(escape(chapter.title))\n"
        }
        try content.write(to: metadata, atomically: true, encoding: .utf8)
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-f", "concat", "-safe", "0", "-i", list.path,
                    "-f", "ffmetadata", "-i", metadata.path]
        if let cover = book.cover {
            let image = work.appendingPathComponent("cover.image")
            try cover.write(to: image)
            args += ["-i", image.path, "-map", "2:v:0", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
        }
        args += ["-map", "0:a:0", "-c:a", "copy", "-map_metadata", "1", "-map_chapters", "1", "-movflags", "+faststart", "-f", "mp4"]
        for item in narrationMetadata(options) { args += ["-metadata", item] }
        args.append(output.path)
        _ = try await runner.run(options.ffmpeg, arguments: args)
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
        let list = try joinList(inputs, work: work)
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-f", "concat", "-safe", "0", "-i", list.path,
                         "-map", "0:a:0", "-c:a", "copy", "-map_metadata", "-1", "-id3v2_version", "3"]
        for item in metadata { arguments += ["-metadata", item] }
        arguments.append(output.path)
        _ = try await runner.run(ffmpeg, arguments: arguments)
        let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw AudiobookError.conversion("The MP3 encoder produced an empty file.") }
    }

    static func speechChunks(_ text: String, limit: Int = 6000, utf8Limit: Int? = nil) -> [String] {
        SpeechText.chunks(text, limit: limit, utf8Limit: utf8Limit)
    }
}
