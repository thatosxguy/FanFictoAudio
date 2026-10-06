import Foundation

public enum NarrationProvider: String, CaseIterable, Identifiable, Sendable {
    case system = "macOS voices", openAI = "OpenAI", elevenLabs = "ElevenLabs"
    public var id: String { rawValue }
    public var speedRange: ClosedRange<Double> { self == .elevenLabs ? 0.7...1.2 : 0.25...4 }
}

public struct APINarration: Sendable {
    public let provider: NarrationProvider
    public let model: String
    public let voice: String
    public let speed: Double
    public let instructions: String
    // Never persist this value to defaults, logs, filenames, or error messages.
    public let apiKey: String
    public init(provider: NarrationProvider, model: String, voice: String, speed: Double = 1,
                instructions: String = "", apiKey: String) {
        self.provider = provider; self.model = model; self.voice = voice
        self.speed = speed; self.instructions = instructions; self.apiKey = apiKey
    }
    public func validate() throws {
        guard provider != .system, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.isEmpty, !voice.isEmpty, provider.speedRange.contains(speed), instructions.count <= 4096 else {
            throw AudiobookError.conversion("Choose an API voice and model, save its API key, and choose a valid speed.")
        }
        guard voice.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw AudiobookError.conversion("The API voice ID must contain only letters, numbers, underscores, or hyphens.")
        }
    }
}

public struct APIVoice: Identifiable, Sendable, Decodable {
    public let id: String
    public let name: String
    enum CodingKeys: String, CodingKey { case id = "voice_id", name }
}

public struct APISpeechClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    public init(transport: @escaping Transport = Self.download) { self.transport = transport }

    public func speechRequest(text: String, settings: APINarration) throws -> URLRequest {
        try settings.validate()
        guard !text.isEmpty, text.unicodeScalars.count <= 1500, settings.provider != .openAI || text.utf8.count <= 2000 else {
            throw AudiobookError.conversion("API speech passages must contain 1 to 1500 characters, with a 2000-byte limit for OpenAI.")
        }
        let url: URL
        var body: [String: Any]
        if settings.provider == .openAI {
            url = URL(string: "https://api.openai.com/v1/audio/speech")!
            body = ["model": settings.model, "voice": settings.voice, "input": text,
                    "response_format": "wav", "speed": settings.speed]
            if !settings.instructions.isEmpty && !settings.model.hasPrefix("tts-1") {
                body["instructions"] = settings.instructions
            }
        } else {
            url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(settings.voice)?output_format=mp3_44100_128")!
            body = ["model_id": settings.model, "text": text, "voice_settings": ["speed": settings.speed]]
        }
        var request = authorized(url: url, provider: settings.provider, key: settings.apiKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func synthesize(text: String, settings: APINarration, destination: URL) async throws {
        let request = try speechRequest(text: text, settings: settings)
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        try Self.check(response, provider: settings.provider)
        guard data.count > 44, data.count <= 64 * 1024 * 1024,
              !(response.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") else {
            throw AudiobookError.conversion("\(settings.provider.rawValue) returned no usable audio.")
        }
        try data.write(to: destination, options: .withoutOverwriting)
    }

    public func elevenLabsVoices(apiKey: String) async throws -> [APIVoice] {
        var voices: [APIVoice] = []
        var cursor: String?
        var seen = Set<String>()
        // A bounded page count prevents an unexpected pagination loop.
        for _ in 0..<20 {
            var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "include_total_count", value: "false")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "next_page_token", value: cursor)) }
            let request = authorized(url: components.url!, provider: .elevenLabs, key: apiKey)
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            try Self.check(response, provider: .elevenLabs)
            struct Page: Decodable { let voices: [APIVoice]; let has_more: Bool?; let next_page_token: String? }
            let page = try JSONDecoder().decode(Page.self, from: data)
            voices += page.voices.filter { seen.insert($0.id).inserted }
            guard page.has_more == true, let next = page.next_page_token, next != cursor else { break }
            cursor = next
        }
        return voices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func authorized(url: URL, provider: NarrationProvider, key: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.setValue(provider == .openAI ? "Bearer \(key)" : key,
                         forHTTPHeaderField: provider == .openAI ? "Authorization" : "xi-api-key")
        return request
    }
    private static func check(_ response: HTTPURLResponse, provider: NarrationProvider) throws {
        guard (200..<300).contains(response.statusCode) else {
            let hint: String
            switch response.statusCode {
            case 401, 403: hint = "Check the API key and its permissions."
            case 429: hint = "Check your quota or rate limit, then retry when ready."
            default: hint = "Check the voice, model, and provider status, then retry when ready."
            }
            // Bodies can echo book text or credentials; never show them in errors.
            throw AudiobookError.conversion("\(provider.rawValue) API returned HTTP \(response.statusCode). \(hint)")
        }
    }
    public static func download(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: NoSpeechRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let downloaded: (URL, URLResponse)
        do { downloaded = try await session.download(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw error }
        let (file, response) = downloaded
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else {
            throw AudiobookError.conversion("The API response was invalid or too large.")
        }
        return (try Data(contentsOf: file), http)
    }
}

private final class NoSpeechRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
