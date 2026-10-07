import Foundation

public enum SpeechText {
    public static func preview(_ text: String, provider: NarrationProvider) -> String {
        let prefix = String(text.prefix(550))
        let bounded = chunks(prefix, limit: 550, utf8Limit: provider == .openAI ? 2000 : nil).first ?? ""
        if let end = bounded.range(of: #"[.!?](?:\s|$)"#, options: [.regularExpression, .backwards]) {
            return String(bounded[..<end.upperBound])
        }
        return bounded
    }

    // Bound PCM disk use and avoid speech engine limits on very long chapters.
    // Prefer paragraph and sentence boundaries; retain every character in order.
    public static func chunks(_ text: String, limit: Int = 6000, utf8Limit: Int? = nil) -> [String] {
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
            // Keep graphemes intact when they fit the passage limit. A pathological
            // single grapheme longer than the limit still needs a scalar split.
            if cutoff < remaining.endIndex,
               let boundary = remaining.indices.prefix(while: { $0 <= cutoff }).last,
               boundary > remaining.startIndex { cutoff = boundary }
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
