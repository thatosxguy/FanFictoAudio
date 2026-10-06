import Foundation
import CryptoKit

struct CachedPassage: Codable {
    let hash: String
    let duration: Double
}

/// Each queue job owns a directory; content/settings hashes isolate incompatible
/// checkpoints. Only completed, checksum-verified passages are reused.
final class ConversionCheckpoint {
    let directory: URL
    private var passages: [String: CachedPassage] = [:]
    private var manifest: URL { directory.appendingPathComponent("passages.json") }

    init(root: URL, book: EPUBBook, options: ExportOptions) throws {
        var hash = SHA256()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        hash.update(data: Data("checkpoint-v2\n".utf8))
        hash.update(data: try encoder.encode(NarrationPreset(voice: options.voice, wordsPerMinute: options.wordsPerMinute,
            bitrate: options.bitrate, mode: options.mode, api: options.api)))
        for string in [book.title, book.author, book.language] { hash.update(data: Data(string.utf8)); hash.update(data: Data([0])) }
        for chapter in book.chapters {
            for string in [chapter.id, chapter.title, chapter.text, options.chapterIDs.contains(chapter.id) ? "selected" : "omitted"] {
                hash.update(data: Data(string.utf8)); hash.update(data: Data([0]))
            }
        }
        if let cover = book.cover { hash.update(data: cover) }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(fingerprint, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode([String: CachedPassage].self, from: data) {
            passages = saved
        }
    }
    func cached(_ name: String) throws -> CachedPassage? {
        guard let saved = passages[name], saved.duration.isFinite, saved.duration > 0 else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), Self.digest(data) == saved.hash else { return nil }
        return saved
    }
    func commit(_ name: String, from source: URL, duration: Double) throws {
        let target = directory.appendingPathComponent(name)
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        try data.write(to: target, options: .atomic)
        passages[name] = CachedPassage(hash: Self.digest(data), duration: duration)
        try JSONEncoder().encode(passages).write(to: manifest, options: .atomic)
    }
    func discardCompleted() { try? FileManager.default.removeItem(at: directory) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
