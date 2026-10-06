import Foundation

public struct DownloadRequest: Codable, Sendable {
    public var operation: String
    public var source: String
    public var output: String
    public var format = "epub"
    public var ini: String?
    public var adult: Bool
    public var work_dir: String?

    public init(operation: String = "download", source: String, output: String, ini: String? = nil, adult: Bool = false) {
        self.operation = operation; self.source = source; self.output = output
        self.ini = ini; self.adult = adult
    }
}

public struct DownloadEvent: Codable, Sendable {
    public var type: String
    public var message: String?
    public var percent: Double?
    public var finalizing: Bool?
    public var status: String?
    public var metadata: [String: String]?
    public var path: String?
    public var backup: String?
    public var urls: [String]?
}

public enum DownloadError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum StoryLinks {
    public static func parse(_ text: String) throws -> [String] {
        var seen = Set<String>()
        let links = try text.components(separatedBy: .newlines).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("#") { return nil }
            guard value.range(of: #"^https?://[^\s]+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let url = URL(string: value), let host = url.host, !host.isEmpty else {
                throw DownloadError.message("Enter one complete http or https story URL per line.")
            }
            return seen.insert(value).inserted ? value : nil
        }
        guard !links.isEmpty else { throw DownloadError.message("Paste at least one story URL first.") }
        return links
    }
}
