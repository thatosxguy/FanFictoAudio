import Foundation

public enum APIUsageError: LocalizedError {
    case budgetReached(String)
    public var errorDescription: String? { switch self { case .budgetReached(let message): return message } }
}

public enum APIPriceBasis: String, Codable, CaseIterable, Sendable, Identifiable {
    case characters = "1 million characters"
    case tokens = "1 million estimated input tokens"
    case minutes = "estimated audio minute"
    public var id: String { rawValue }
}

/// User-entered, all-in estimates. They are not provider billing records.
public struct APIBudget: Sendable {
    public let characterLimit: Int?
    public let costLimit: Double?
    public let price: Double?
    public let basis: APIPriceBasis
    public init(characterLimit: Int? = nil, costLimit: Double? = nil, price: Double? = nil, basis: APIPriceBasis = .characters) {
        self.characterLimit = characterLimit; self.costLimit = costLimit; self.price = price; self.basis = basis
    }
    public func estimate(_ text: String, speed: Double) -> Double? {
        estimate(characters: text.unicodeScalars.count, bytes: text.utf8.count, words: text.split(whereSeparator: { $0.isWhitespace }).count, speed: speed)
    }
    public func estimate(characters: Int, bytes: Int, words: Int, speed: Double) -> Double? {
        guard let price, price.isFinite, price > 0 else { return nil }
        switch basis {
        case .characters: return Double(characters) / 1_000_000 * price
        case .tokens: return Double(bytes) / 3 / 1_000_000 * price
        case .minutes: return Double(words) / (175 * speed) * price
        }
    }
}

public struct APIUsageSummary: Codable, Sendable, Equatable {
    public var since = Date()
    public var requests = 0
    public var characters = 0
    public var estimatedCost = 0.0
    public var unpricedRequests = 0
    public init() {}
}

/// Counts every dispatched speech attempt, including previews and retries.
/// No book text or credentials are stored. Reservations are committed before
/// dispatch, conservatively retaining failed/cancelled attempts.
public actor APIUsageLedger {
    private var summary = APIUsageSummary()
    private let storage: URL?
    private var loadFailed = false
    public init(storage: URL? = nil) {
        self.storage = storage
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            do {
                let saved = try JSONDecoder().decode(APIUsageSummary.self, from: Data(contentsOf: storage))
                guard saved.requests >= 0, saved.characters >= 0, saved.unpricedRequests >= 0, saved.unpricedRequests <= saved.requests,
                      saved.estimatedCost.isFinite, saved.estimatedCost >= 0 else { throw AudiobookError.conversion("Invalid usage totals.") }
                summary = saved
            }
            catch { loadFailed = true }
        }
    }
    public func snapshot() -> APIUsageSummary { summary }
    public func reserve(text: String, settings: APINarration, budget: APIBudget?) throws {
        guard !loadFailed else { throw AudiobookError.conversion("The saved AI usage record could not be read. Reset usage before sending more text.") }
        let count = text.unicodeScalars.count
        let cost = budget?.estimate(text, speed: settings.speed)
        if let limit = budget?.characterLimit, count > limit - summary.characters {
            throw APIUsageError.budgetReached("AI character budget reached. Increase the limit or reset usage to continue.")
        }
        if let limit = budget?.costLimit {
            guard let cost, limit.isFinite, limit > 0 else {
                throw AudiobookError.conversion("Enter a positive estimated rate before using a cost budget.")
            }
            guard summary.unpricedRequests == 0 else {
                throw AudiobookError.conversion("Earlier requests have no cost estimate. Reset usage before starting a cost budget.")
            }
            guard summary.estimatedCost + cost <= limit else {
                throw APIUsageError.budgetReached("Estimated AI cost budget reached. Increase the limit or reset usage to continue.")
            }
        }
        var next = summary
        next.requests += 1; next.characters += count
        if let cost { next.estimatedCost += cost } else { next.unpricedRequests += 1 }
        try save(next)
        summary = next
    }
    public func reset() throws { let next = APIUsageSummary(); try save(next); summary = next; loadFailed = false }
    private func save(_ next: APIUsageSummary) throws {
        if let storage {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: storage, options: .atomic)
        }
    }
}
