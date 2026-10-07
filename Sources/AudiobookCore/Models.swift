import Foundation

public enum AudiobookError: LocalizedError, Sendable {
    case invalidEPUB(String)
    case conversion(String)
    public var errorDescription: String? {
        switch self {
        case .invalidEPUB(let message), .conversion(let message): return message
        }
    }
}

public struct BookChapter: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let text: String
    public let includedByDefault: Bool
    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
    public init(id: String, title: String, text: String, includedByDefault: Bool = true) {
        self.id = id; self.title = title; self.text = text; self.includedByDefault = includedByDefault
    }
}

public struct EPUBBook: Sendable {
    public let title: String
    public let author: String
    public let language: String
    public let chapters: [BookChapter]
    public let source: URL
    public let warnings: [String]
    public init(title: String, author: String, language: String, chapters: [BookChapter], source: URL, warnings: [String] = []) {
        self.title = title; self.author = author; self.language = language
        self.chapters = chapters; self.source = source; self.warnings = warnings
    }
}

public struct SystemVoice: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let language: String
    public var label: String { "\(name) · \(language.replacingOccurrences(of: "_", with: "-"))" }
    public static func parse(_ listing: String) -> [SystemVoice] {
        let regex = try! NSRegularExpression(pattern: #"^(.+?)\s+([A-Za-z]{2,3}[_-][A-Za-z0-9_-]+)\s+#"#)
        return listing.components(separatedBy: .newlines).compactMap { line in
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let name = Range(match.range(at: 1), in: line),
                  let language = Range(match.range(at: 2), in: line) else { return nil }
            return SystemVoice(name: String(line[name]).trimmingCharacters(in: .whitespaces), language: String(line[language]))
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

public enum ExportMode: String, CaseIterable, Identifiable, Sendable {
    case single = "One audiobook MP3"
    case chapters = "MP3 per chapter"
    public var id: String { rawValue }
}

public enum SpeechRate {
    public static let allowedRange = 80...1000
    public static var sliderRange: ClosedRange<Double> {
        Double(allowedRange.lowerBound)...Double(allowedRange.upperBound)
    }
}

public struct ExportOptions: Sendable {
    public let voice: String
    public let wordsPerMinute: Int
    public let bitrate: Int
    public let mode: ExportMode
    public let chapterIDs: Set<String>
    public let ffmpeg: URL
    public init(voice: String, wordsPerMinute: Int, bitrate: Int, mode: ExportMode, chapterIDs: Set<String>, ffmpeg: URL) {
        self.voice = voice; self.wordsPerMinute = wordsPerMinute; self.bitrate = bitrate
        self.mode = mode; self.chapterIDs = chapterIDs; self.ffmpeg = ffmpeg
    }
}

public struct ExportProgress: Sendable {
    public let fraction: Double
    public let message: String
    public init(_ fraction: Double, _ message: String) { self.fraction = fraction; self.message = message }
}

public enum FileNames {
    public static func safe(_ text: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\: \n\r\t").union(.controlCharacters)
        let cleaned = text.components(separatedBy: illegal).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let limited = String(cleaned.prefix(100))
        return limited.isEmpty ? "Audiobook" : limited
    }
}
