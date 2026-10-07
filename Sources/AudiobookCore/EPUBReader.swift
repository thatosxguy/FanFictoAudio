import Foundation

public enum EPUBReader {
    public static func read(_ url: URL) throws -> EPUBBook {
        let archive = try ZIPArchive(url: url)
        guard let mime = String(data: try archive.read("mimetype"), encoding: .utf8),
              mime.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw AudiobookError.invalidEPUB("This archive is not an EPUB book.")
        }
        let container = try document(archive.read("META-INF/container.xml"))
        guard let root = try container.nodes(forXPath: "//*[local-name()='rootfile']").first as? XMLElement,
              let packagePath = root.attribute(forName: "full-path")?.stringValue else {
            throw AudiobookError.invalidEPUB("The EPUB does not identify a package document.")
        }
        let opfPath = try resolve(packagePath, relativeTo: "")
        let package = try document(archive.read(opfPath))
        let title = try firstText(package, "//*[local-name()='metadata']/*[local-name()='title']")
        let author = try package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ")
        let language = try firstText(package, "//*[local-name()='metadata']/*[local-name()='language']")
        var items: [String: (path: String, type: String, properties: String)] = [:]
        for node in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let item = node as? XMLElement, let id = item.attr("id"), let href = item.attr("href") else { continue }
            guard items[id] == nil else { throw AudiobookError.invalidEPUB("Duplicate EPUB manifest identifier: \(id)") }
            items[id] = (try resolve(href, relativeTo: opfPath), item.attr("media-type") ?? "", item.attr("properties") ?? "")
        }
        var encrypted: Set<String> = []
        if archive.entries["META-INF/encryption.xml"] != nil {
            let encryption = try document(archive.read("META-INF/encryption.xml"))
            for ref in try encryption.nodes(forXPath: "//*[local-name()='CipherReference']") {
                if let uri = (ref as? XMLElement)?.attr("URI") { encrypted.insert(try resolve(uri, relativeTo: "")) }
            }
        }
        var labels: [String: String] = [:]
        var warnings: [String] = []
        if let nav = items.values.first(where: { $0.properties.split(separator: " ").contains("nav") }) {
            do {
                let doc = try document(archive.read(nav.path), html: true)
                let navigation = try doc.nodes(forXPath: "//*[local-name()='nav' and (@*[local-name()='type']='toc' or @role='doc-toc')]").first
                let links = try (navigation ?? doc).nodes(forXPath: ".//*[local-name()='a' and @href]")
                for link in links {
                    guard let element = link as? XMLElement, let href = element.attr("href"), let label = element.stringValue else { continue }
                    if let path = try? resolve(href, relativeTo: nav.path), labels[path] == nil { labels[path] = normalized(label) }
                }
            } catch { warnings.append("The navigation labels could not be read; document headings are used instead.") }
        } else if let ncx = items.values.first(where: { $0.type == "application/x-dtbncx+xml" }) {
            do {
                let doc = try document(archive.read(ncx.path))
                for point in try doc.nodes(forXPath: "//*[local-name()='navPoint']") {
                    guard let content = try point.nodes(forXPath: "./*[local-name()='content']").first as? XMLElement,
                          let href = content.attr("src") else { continue }
                    let label = try point.nodes(forXPath: "./*[local-name()='navLabel']/*[local-name()='text']").first?.stringValue ?? ""
                    let path = try resolve(href, relativeTo: ncx.path)
                    if labels[path] == nil { labels[path] = normalized(label) }
                }
            } catch { warnings.append("The navigation labels could not be read; document headings are used instead.") }
        }
        var chapters: [BookChapter] = []
        var totalTextBytes = 0
        for (index, node) in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']").enumerated() {
            guard let ref = node as? XMLElement, let id = ref.attr("idref"), let item = items[id] else {
                throw AudiobookError.invalidEPUB("The EPUB reading order refers to a missing document.")
            }
            guard !encrypted.contains(item.path) else { throw AudiobookError.invalidEPUB("This EPUB has protected text. Export requires an EPUB without DRM.") }
            guard ["application/xhtml+xml", "text/html"].contains(item.type) else {
                warnings.append("Skipped a non-text reading-order item: \(item.path)")
                continue
            }
            let chapterData = try archive.read(item.path)
            totalTextBytes += chapterData.count
            guard totalTextBytes <= 64 * 1024 * 1024 else { throw AudiobookError.invalidEPUB("This EPUB exceeds the 64 MB text limit.") }
            let doc = try document(chapterData, html: true)
            guard let body = try doc.nodes(forXPath: "//*[local-name()='body']").first else {
                throw AudiobookError.invalidEPUB("No readable body in \(item.path).")
            }
            let text = readableText(body)
            guard !text.isEmpty else { warnings.append("Skipped an empty document: \(item.path)"); continue }
            let heading = try body.nodes(forXPath: ".//*[local-name()='h1' or local-name()='h2' or local-name()='h3']").first?.stringValue
            let chapterTitle = [labels[item.path], heading.map(normalized)].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "Section \(index + 1)"
            let isNavigation = item.properties.split(separator: " ").contains("nav")
            chapters.append(BookChapter(id: "\(index):\(id)", title: chapterTitle, text: text,
                                        includedByDefault: ref.attr("linear") != "no" && !isNavigation))
        }
        guard !chapters.isEmpty else { throw AudiobookError.invalidEPUB("This EPUB has no readable text in its reading order. Scanned pages cannot be narrated.") }
        return EPUBBook(title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                        author: author, language: language, chapters: chapters, source: url, warnings: warnings)
    }

    static func resolve(_ href: String, relativeTo document: String) throws -> String {
        let fragmentless = href.components(separatedBy: "#")[0].components(separatedBy: "?")[0]
        guard let decoded = fragmentless.removingPercentEncoding, !decoded.contains(":"), !decoded.hasPrefix("/"),
              !decoded.contains("\\"), !decoded.contains("\0") else { throw AudiobookError.invalidEPUB("Invalid EPUB resource reference: \(href)") }
        if decoded.isEmpty { return document }
        var components = document.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { throw AudiobookError.invalidEPUB("An EPUB resource reference escapes the book.") }
                components.removeLast()
            } else { components.append(String(part)) }
        }
        return components.joined(separator: "/")
    }

    private static func document(_ data: Data, html: Bool = false) throws -> XMLDocument {
        // Never fetch external DTDs, entities, or resources from the book.
        let options: XMLNode.Options = html ? [.documentTidyHTML, .nodeLoadExternalEntitiesNever] : [.nodeLoadExternalEntitiesNever]
        do { return try XMLDocument(data: data, options: options) }
        catch { throw AudiobookError.invalidEPUB("An EPUB document could not be parsed: \(error.localizedDescription)") }
    }

    private static func firstText(_ doc: XMLDocument, _ xpath: String) throws -> String {
        normalized(try doc.nodes(forXPath: xpath).first?.stringValue ?? "")
    }

    static func normalized(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    static func readableText(_ node: XMLNode) -> String {
        let skipped: Set<String> = ["script", "style", "head", "noscript", "svg"]
        let blocks: Set<String> = ["p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "tr", "dt", "dd", "pre", "hr"]
        var output = ""
        func visit(_ node: XMLNode) {
            if node.kind == .text { output += node.stringValue ?? ""; return }
            let name = (node.localName ?? node.name ?? "").lowercased()
            guard !skipped.contains(name) else { return }
            if let element = node as? XMLElement,
               element.attr("hidden") != nil || element.attr("aria-hidden") == "true" { return }
            if name == "br" { output += "\n"; return }
            if blocks.contains(name) { output += "\n\n" }
            if name == "td" || name == "th" { output += " " }
            for child in node.children ?? [] { visit(child) }
            if blocks.contains(name) { output += "\n\n" }
        }
        visit(node)
        // Speech-control markup in a book must remain prose, not instructions to say.
        output = output.replacingOccurrences(of: "[[", with: "[ [").replacingOccurrences(of: "]]", with: "] ]")
        return output.components(separatedBy: .newlines).map(normalized).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

private extension XMLElement {
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
}
