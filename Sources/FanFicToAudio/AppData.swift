import Foundation
import CryptoKit
import AudiobookCore

enum AppData {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanFicToAudio", isDirectory: true)
    }
}

@MainActor extension AppModel {
    var pricingID: String { provider.rawValue + "." + (provider == .openAI ? openAIModel : elevenModel) }
    func savePricing() {
        guard !restoringPricing else { return }
        UserDefaults.standard.set(["price": aiPrice, "basis": aiPriceBasis.rawValue], forKey: "aiPricing." + pricingID)
    }
    func restorePricing() {
        restoringPricing = true
        let saved = UserDefaults.standard.dictionary(forKey: "aiPricing." + pricingID)
        aiPrice = saved?["price"] as? String ?? ""
        aiPriceBasis = APIPriceBasis(rawValue: saved?["basis"] as? String ?? "") ?? .characters
        restoringPricing = false
    }
    func budget(priceID: String? = nil) throws -> APIBudget {
        func positive(_ value: String, name: String) throws -> Double? {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            guard let number = Double(value), number.isFinite, number > 0 else { throw AudiobookError.conversion("Enter a positive number for \(name), or leave it blank.") }
            return number
        }
        let charValue = try positive(aiCharacterLimit, name: "the character budget")
        guard charValue == nil || (charValue! < Double(Int.max) && charValue!.rounded(.down) == charValue!) else {
            throw AudiobookError.conversion("The character budget must be a whole number.")
        }
        let saved = priceID.flatMap { UserDefaults.standard.dictionary(forKey: "aiPricing." + $0) }
        let priceText = priceID == nil ? aiPrice : saved?["price"] as? String ?? ""
        let basis = priceID == nil ? aiPriceBasis : APIPriceBasis(rawValue: saved?["basis"] as? String ?? "") ?? .characters
        let cost = try positive(aiCostLimit, name: "the cost budget")
        let price = try positive(priceText, name: "the estimated rate")
        if cost != nil && price == nil && (provider != .system || priceID != nil) { throw AudiobookError.conversion("Enter an estimated all-in rate for each queued AI model before using a cost budget.") }
        return APIBudget(characterLimit: charValue.map(Int.init), costLimit: cost, price: price, basis: basis)
    }
    func queuedBudgets() throws -> [String: APIBudget] {
        var budgets: [String: APIBudget] = [:]
        for job in audiobookQueue.jobs where job.state == .queued {
            if let preset = job.narration, preset.provider != .system { budgets[preset.pricingID] = try budget(priceID: preset.pricingID) }
        }
        return budgets
    }
    func refreshUsage() { Task { let snapshot = await usageLedger.snapshot(); if snapshot != usageSummary { usageSummary = snapshot } } }
    func resetUsage() {
        guard !busy, !isPreviewing else { return }
        Task {
            do { try await usageLedger.reset(); refreshUsage() }
            catch { errorMessage = error.localizedDescription }
        }
    }
    var openBookEstimate: String {
        guard provider != .system, let book else { return "" }
        let chapters = book.chapters.filter { selectedChapters.contains($0.id) }
        return estimateDescription(chapters, speed: apiSpeed, budget: try? budget())
    }
    func estimateDescription(_ chapters: [BookChapter], speed: Double, budget: APIBudget?) -> String {
        let count = chapters.reduce(0) { $0 + $1.characterCount }
        let cost = budget?.estimate(characters: count, bytes: chapters.reduce(0) { $0 + $1.utf8Count },
            words: chapters.reduce(0) { $0 + $1.wordCount }, speed: speed)
        return "\(count.formatted()) characters" + (cost.map { String(format: " · estimated $%.3f", $0) } ?? " · enter a rate for a cost estimate")
    }
    func calculateQueueEstimate() {
        guard !busy else { return }
        isEstimating = true; queueEstimate = "Reading queued books…"
        let jobs = audiobookQueue.jobs.filter { $0.state == .queued }
        Task {
            defer { isEstimating = false }
            do {
                var count = 0, cost = 0.0, priced = true
                for job in jobs {
                    let preset = job.narration
                    let jobProvider = preset?.provider ?? provider
                    guard jobProvider != .system else { continue }
                    let book = try await EPUBLibrary.shared.read(job.source)
                    let ids = job.chapterIDs ?? Set(book.chapters.filter(\.includedByDefault).map(\.id))
                    let chapters = book.chapters.filter { ids.contains($0.id) }
                    let characterCount = chapters.reduce(0) { $0 + $1.characterCount }
                    let policy = try budget(priceID: preset?.pricingID)
                    let estimate = policy.estimate(characters: characterCount, bytes: chapters.reduce(0) { $0 + $1.utf8Count },
                        words: chapters.reduce(0) { $0 + $1.wordCount }, speed: preset?.speed ?? apiSpeed)
                    count += characterCount
                    if let estimate { cost += estimate } else { priced = false }
                }
                queueEstimate = "Queue: \(count.formatted()) AI characters" + (priced ? String(format: " · estimated $%.3f", cost) : " · some models have no estimated rate")
            } catch { queueEstimate = "Estimate unavailable: \(error.localizedDescription)" }
        }
    }
    func saveSelectedJobSettings() {
        guard !busy, let id = selectedQueueJob else { return }
        do {
            let preset = NarrationPreset(voice: voice, wordsPerMinute: Int(rate), bitrate: bitrate, mode: mode, api: try apiSettings())
            audiobookQueue.updateSettings(id, chapterIDs: selectedChapters, narration: preset)
            queueEstimate = ""
        } catch { errorMessage = error.localizedDescription }
    }
    func singleCheckpoint(_ book: EPUBBook) -> URL {
        let id = SHA256.hash(data: Data(book.source.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return storageRoot.appendingPathComponent("Checkpoints/single-" + id, isDirectory: true)
    }
}
