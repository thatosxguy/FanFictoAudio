import Foundation

/// Share preview and conversion reads; invalidate on file changes and bound retained text.
public actor EPUBLibrary {
    public static let shared = EPUBLibrary()
    private struct Stamp: Hashable { let url: URL; let size: Int; let modified: Date? }
    private struct Entry { let stamp: Stamp; let book: EPUBBook; let bytes: Int }
    private var cache: [Entry] = []
    private var pending: [Stamp: Task<EPUBBook, Error>] = [:]

    public init() {}
    public func read(_ source: URL) async throws -> EPUBBook {
        let url = source.resolvingSymlinksInPath().standardizedFileURL
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = Stamp(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate)
        if let index = cache.firstIndex(where: { $0.stamp == stamp }) {
            let entry = cache.remove(at: index); cache.append(entry); return entry.book
        }
        cache.removeAll { $0.stamp.url == url }
        if let task = pending[stamp] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) { try EPUBReader.read(url) }
        pending[stamp] = task
        defer { pending[stamp] = nil }
        let book = try await task.value
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard after.fileSize == values.fileSize, after.contentModificationDate == values.contentModificationDate else {
            throw AudiobookError.invalidEPUB("The EPUB changed while it was being read. Open it again.")
        }
        let bytes = book.chapters.reduce(0) { $0 + $1.text.utf8.count }
        if bytes <= 64 * 1024 * 1024 {
            cache.append(Entry(stamp: stamp, book: book, bytes: bytes))
            while cache.count > 3 || cache.reduce(0, { $0 + $1.bytes }) > 64 * 1024 * 1024 { cache.removeFirst() }
        }
        return book
    }
}
