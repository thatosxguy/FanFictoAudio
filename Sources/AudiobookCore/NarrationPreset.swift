import Foundation

/// Safe to save with the queue. API credentials are deliberately absent.
public struct NarrationPreset: Codable, Sendable {
    public let provider: NarrationProvider
    public let model: String
    public let apiVoice: String
    public let speed: Double
    public let instructions: String
    public let voice: String
    public let wordsPerMinute: Int
    public let bitrate: Int
    public let mode: ExportMode
    public var pricingID: String { provider.rawValue + "." + model }
    public init(voice: String, wordsPerMinute: Int, bitrate: Int, mode: ExportMode, api: APINarration?) {
        provider = api?.provider ?? .system; model = api?.model ?? ""; apiVoice = api?.voice ?? ""
        speed = api?.speed ?? 1; instructions = api?.instructions ?? ""
        self.voice = voice; self.wordsPerMinute = wordsPerMinute; self.bitrate = bitrate; self.mode = mode
    }
    public func api(key: String) -> APINarration? {
        provider == .system ? nil : APINarration(provider: provider, model: model, voice: apiVoice, speed: speed, instructions: instructions, apiKey: key)
    }
}
