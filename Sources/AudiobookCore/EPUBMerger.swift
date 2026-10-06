import Foundation
import CZlib

/// Namespace each source archive so its chapter, stylesheet, and image links stay intact.
public enum EPUBMerger {
    public static func combine(_ sources: [URL], title: String, destination: URL) throws -> EPUBBook {
        guard sources.count >= 2, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudiobookError.invalidEPUB("Choose at least two EPUBs and a title for the series.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path),
              !sources.contains(where: { $0.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }) else {
            throw AudiobookError.invalidEPUB("Choose a new EPUB filename. Existing books are preserved.")
        }
        var resources: [(String, Data)] = [("mimetype", Data("application/epub+zip".utf8))]
        var manifest = ["<item id=\"series-nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"]
        var spine: [String] = []
        var navigation: [String] = []
        var authors: [String] = []
        var language = "en"
        var totalBytes = 0
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let book = try EPUBReader.read(source)
            if index == 0, !book.language.isEmpty { language = book.language }
            if !book.author.isEmpty && !authors.contains(book.author) { authors.append(book.author) }
            let archive = try ZIPArchive(url: source)
            guard archive.entries["META-INF/encryption.xml"] == nil else {
                throw AudiobookError.invalidEPUB("\(book.title) contains encrypted or obfuscated resources. Use an EPUB without protected resources to combine it.")
            }
            let container = try xml(archive.read("META-INF/container.xml"))
            guard let root = try container.nodes(forXPath: "//*[local-name()='rootfile']").first as? XMLElement,
                  let path = root.attribute(forName: "full-path")?.stringValue else {
                throw AudiobookError.invalidEPUB("Missing EPUB package.")
            }
            let packagePath = try EPUBReader.resolve(path, relativeTo: "")
            let package = try xml(archive.read(packagePath))
            let prefix = "books/\(index + 1)/"
            let identifier = "b\(index + 1)-"
            // Preserve archive-relative paths inside each book's namespace.
            for path in archive.entries.keys.sorted() where path != "mimetype" && !path.hasPrefix("META-INF/") && !path.hasSuffix("/") {
                try Task.checkCancellation()
                let data = try archive.read(path)
                totalBytes += data.count
                guard totalBytes <= 240 * 1024 * 1024 else { throw AudiobookError.invalidEPUB("The combined EPUB exceeds the 240 MB resource limit.") }
                resources.append(("EPUB/" + prefix + path, data))
            }
            var paths: [String: String] = [:]
            for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
                guard let id = attr(item, "id"), let href = attr(item, "href") else { continue }
                let itemPath = try EPUBReader.resolve(href, relativeTo: packagePath)
                paths[id] = itemPath
                var attributes: [String] = []
                for attribute in item.attributes ?? [] {
                    guard let name = attribute.name, let value = attribute.stringValue else { continue }
                    let updated: String
                    switch name {
                    case "id", "fallback", "media-overlay": updated = identifier + value
                    case "href": updated = encodedPath(prefix + itemPath)
                    case "properties":
                        updated = value.split(separator: " ").filter { $0 != "nav" && (index == 0 || $0 != "cover-image") }.joined(separator: " ")
                    default: updated = value
                    }
                    if !updated.isEmpty { attributes.append("\(name)=\"\(escape(updated))\"") }
                }
                manifest.append("<item \(attributes.joined(separator: " "))/>")
            }
            let dividerID = "\(identifier)divider"
            // Avoid colliding with any original resource name.
            let divider = "\(prefix)series-title-\(UUID().uuidString).xhtml"
            manifest.append("<item id=\"\(dividerID)\" href=\"\(divider)\" media-type=\"application/xhtml+xml\"/>")
            spine.append("<itemref idref=\"\(dividerID)\"/>")
            let titlePage = "<h1>Book \(index + 1): \(escape(book.title))</h1><p>\(escape(book.author))</p>"
            resources.append(("EPUB/" + divider, Data(xhtml(title: book.title, body: titlePage, language: language).utf8)))
            var links: [String] = []
            let chapterByID = Dictionary(uniqueKeysWithValues: book.chapters.map { ($0.id, $0) })
            for (spineIndex, node) in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']").enumerated() {
                guard let ref = node as? XMLElement else { continue }
                guard let id = attr(ref, "idref"), let resourcePath = paths[id] else { throw AudiobookError.invalidEPUB("Missing reading-order resource.") }
                var attributes = ["idref=\"\(escape(identifier + id))\""]
                let chapter = chapterByID["\(spineIndex):\(id)"]
                if chapter?.includedByDefault == false { attributes.append("linear=\"no\"") }
                else if let linear = attr(ref, "linear") { attributes.append("linear=\"\(escape(linear))\"") }
                spine.append("<itemref \(attributes.joined(separator: " "))/>")
                // EPUBReader labels are in readable spine order, including optional extras.
                if let chapter {
                    links.append("<li><a href=\"\(escape(encodedPath(prefix + resourcePath)))\">\(escape(chapter.title))</a></li>")
                }
            }
            navigation.append("<li><a href=\"\(escape(divider))\">\(escape(book.title))</a><ol>\(links.joined())</ol></li>")
        }
        let authorXML = authors.map { "<dc:creator>\(escape($0))</dc:creator>" }.joined()
        let modified = ISO8601DateFormatter().string(from: Date())
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="series-id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="series-id">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(escape(title))</dc:title>\(authorXML)<dc:language>\(escape(language))</dc:language><meta property="dcterms:modified">\(modified)</meta></metadata>
        <manifest>\(manifest.joined())</manifest><spine>\(spine.joined())</spine></package>
        """
        resources.append(("META-INF/container.xml", Data("<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"EPUB/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)))
        resources.append(("EPUB/package.opf", Data(opf.utf8)))
        resources.append(("EPUB/nav.xhtml", Data(xhtml(title: title, body: "<nav epub:type=\"toc\"><h1>Contents</h1><ol>\(navigation.joined())</ol></nav>", language: language).utf8)))
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".series-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: temp) }
        try EPUBZIPWriter.encode(resources).write(to: temp, options: .withoutOverwriting)
        // Validate the finished archive before committing it to the chosen destination.
        let verified = try EPUBReader.read(temp)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temp, to: destination)
        return EPUBBook(title: verified.title, author: verified.author, language: verified.language, chapters: verified.chapters, source: destination, warnings: verified.warnings)
    }
    private static func attr(_ node: XMLElement, _ name: String) -> String? { node.attribute(forName: name)?.stringValue }
    private static func xml(_ data: Data) throws -> XMLDocument { try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func encodedPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"))!
    }
    private static func xhtml(title: String, body: String, language: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"\(escape(language))\"><head><title>\(escape(title))</title></head><body>\(body)</body></html>"
    }
}

/// Standard ZIP: the first mimetype entry is stored; all other resources are deflated.
enum EPUBZIPWriter {
    static func encode(_ resources: [(String, Data)]) throws -> Data {
        guard resources.count < Int(UInt16.max), Set(resources.map(\.0)).count == resources.count else { throw AudiobookError.invalidEPUB("Too many or duplicate EPUB resources.") }
        var output = Data(), directory = Data()
        for (name, data) in resources {
            let path = Data(name.utf8)
            guard path.count < Int(UInt16.max), data.count < Int(UInt32.max), output.count < Int(UInt32.max) else { throw AudiobookError.invalidEPUB("EPUB resource too large.") }
            let crc = data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
            var payload = data
            let method: UInt16 = name == "mimetype" ? 0 : 8
            if method == 8 {
                var length = compressBound(uLong(data.count))
                var compressed = Data(count: Int(length))
                let status = compressed.withUnsafeMutableBytes { dest in data.withUnsafeBytes { source in
                    compress2(dest.bindMemory(to: Bytef.self).baseAddress, &length, source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
                } }
                guard status == Z_OK, length >= 6 else { throw AudiobookError.invalidEPUB("Could not compress EPUB resources.") }
                payload = compressed.subdata(in: 2..<Int(length) - 4)
            }
            let offset = output.count
            output.le(UInt32(0x04034b50)); output.le(UInt16(20)); output.le(UInt16(0x0800)); output.le(method)
            output.le(UInt16(0)); output.le(UInt16(0)); output.le(UInt32(crc)); output.le(UInt32(payload.count)); output.le(UInt32(data.count))
            output.le(UInt16(path.count)); output.le(UInt16(0)); output.append(path); output.append(payload)
            directory.le(UInt32(0x02014b50)); directory.le(UInt16(20)); directory.le(UInt16(20)); directory.le(UInt16(0x0800)); directory.le(method)
            directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt32(crc)); directory.le(UInt32(payload.count)); directory.le(UInt32(data.count))
            directory.le(UInt16(path.count)); directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt32(0)); directory.le(UInt32(offset)); directory.append(path)
        }
        let start = output.count; output.append(directory)
        output.le(UInt32(0x06054b50)); output.le(UInt16(0)); output.le(UInt16(0)); output.le(UInt16(resources.count)); output.le(UInt16(resources.count))
        output.le(UInt32(directory.count)); output.le(UInt32(start)); output.le(UInt16(0))
        return output
    }
}
private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}
