import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import AudiobookCore

@MainActor
final class AppModel: ObservableObject {
    @Published var stage = 0
    @Published var book: EPUBBook?
    @Published var selectedChapters: Set<String> = []
    @Published var focusedChapter: String?
    @Published var voices: [SystemVoice] = []
    @Published var voice = UserDefaults.standard.string(forKey: "selectedVoice") ?? "" {
        didSet { UserDefaults.standard.set(voice, forKey: "selectedVoice") }
    }
    @Published var rate = UserDefaults.standard.object(forKey: "speakingRate") as? Double ?? 175 {
        didSet { UserDefaults.standard.set(rate, forKey: "speakingRate") }
    }
    @Published var bitrate = UserDefaults.standard.object(forKey: "mp3Bitrate") as? Int ?? 128 {
        didSet { UserDefaults.standard.set(bitrate, forKey: "mp3Bitrate") }
    }
    @Published var provider = NarrationProvider(rawValue: UserDefaults.standard.string(forKey: "narrationProvider") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "narrationProvider"); apiKeyDraft = ""; refreshKeyStatus(); restorePricing(); stopPreview() }
    }
    @Published var openAIModel = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-4o-mini-tts" { didSet {
        UserDefaults.standard.set(openAIModel, forKey: "openAIModel"); restorePricing()
        if openAIModel.hasPrefix("tts-1"), ["ballad", "verse", "marin", "cedar"].contains(openAIVoice) { openAIVoice = "coral" }
    } }
    @Published var openAIVoice = UserDefaults.standard.string(forKey: "openAIVoice") ?? "marin" { didSet { UserDefaults.standard.set(openAIVoice, forKey: "openAIVoice") } }
    @Published var elevenModel = UserDefaults.standard.string(forKey: "elevenModel") ?? "eleven_multilingual_v2" { didSet { UserDefaults.standard.set(elevenModel, forKey: "elevenModel"); restorePricing() } }
    @Published var elevenVoice = UserDefaults.standard.string(forKey: "elevenVoice") ?? "" { didSet { UserDefaults.standard.set(elevenVoice, forKey: "elevenVoice") } }
    @Published var apiSpeed = 1.0
    @Published var instructions = ""
    @Published var apiKeyDraft = ""
    @Published var hasAPIKey = false
    @Published var apiKeyStatus = ""
    @Published var apiVoices: [APIVoice] = []
    @Published var loadingAPIVoices = false
    @Published var seriesJobIDs: Set<UUID> = []
    @Published var seriesTitle = ""
    @Published var isCombining = false
    @Published var mode: ExportMode = .single
    @Published var ffmpeg = SpeechTools.findFFmpeg()
    @Published var downloadInProgress = false
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var isPreviewing = false
    @Published var progress = 0.0
    @Published var status = "Choose an EPUB to begin."
    @Published var errorMessage: String?
    @Published var exportedURL: URL?
    @Published var voiceSearch = ""
    @Published var isDropTarget = false
    let audiobookQueue: AudiobookQueue
    let usageLedger: APIUsageLedger
    let storageRoot: URL
    @Published var usageSummary = APIUsageSummary()
    @Published var aiCharacterLimit = UserDefaults.standard.string(forKey: "aiCharacterLimit") ?? "" { didSet { UserDefaults.standard.set(aiCharacterLimit, forKey: "aiCharacterLimit") } }
    @Published var aiCostLimit = UserDefaults.standard.string(forKey: "aiCostLimit") ?? "" { didSet { UserDefaults.standard.set(aiCostLimit, forKey: "aiCostLimit") } }
    @Published var aiPrice = "" { didSet { savePricing() } }
    @Published var aiPriceBasis: APIPriceBasis = .characters { didSet { savePricing() } }
    @Published var queueEstimate = ""
    @Published var isEstimating = false
    var restoringPricing = false
    @Published var selectedQueueJob: UUID? {
        didSet {
            guard !restoringSelection else { return }
            guard selectedQueueJob != oldValue else { return }
            guard canSelectQueue || audiobookQueue.isRunning else {
                restoringSelection = true; selectedQueueJob = oldValue; restoringSelection = false; return
            }
            audiobookQueue.rememberSelection(selectedQueueJob)
            if selectedQueueJob == nil && oldValue != nil && !audiobookQueue.isRunning {
                loadTask?.cancel(); loadGeneration = UUID(); isLoading = false
                book = nil; selectedChapters = []; focusedChapter = nil; exportedURL = nil
                status = "Choose an EPUB to begin."; return
            }
            guard let job = audiobookQueue.jobs.first(where: { $0.id == selectedQueueJob }), !isExporting, !downloadInProgress else { return }
            if !audiobookQueue.isRunning { loadBook(job.source, chapterIDs: job.chapterIDs, queueID: job.id) }
        }
    }
    @Published var audiobookFolder = UserDefaults.standard.string(forKey: "audiobookQueueFolder").map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(audiobookFolder?.path, forKey: "audiobookQueueFolder") }
    }
    private var queueObservation: AnyCancellable?
    private var restoringSelection = false
    private var activeBookObservation: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var exportTask: Task<Void, Never>?
    private var combineTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var exportRunner: ProcessRunner?
    private var previewRunner: ProcessRunner?

    init(storageRoot: URL = AppData.directory) {
        self.storageRoot = storageRoot
        audiobookQueue = AudiobookQueue(storage: storageRoot.appendingPathComponent("queue.json"), checkpointRoot: storageRoot.appendingPathComponent("Checkpoints", isDirectory: true))
        usageLedger = APIUsageLedger(storage: storageRoot.appendingPathComponent("ai-usage.json"))
        refreshKeyStatus()
        restorePricing()
        activeBookObservation = audiobookQueue.$activeBook.compactMap { $0 }.sink { [weak self] value in
            guard let self else { return }
            self.loadTask?.cancel(); self.loadGeneration = UUID(); self.isLoading = false
            self.selectedQueueJob = value.id
            let ids = self.audiobookQueue.jobs.first(where: { $0.id == value.id })?.chapterIDs
            self.applyBook(value.book, chapterIDs: ids)
        }
        if let id = audiobookQueue.selectedID ?? audiobookQueue.jobs.first?.id {
            selectedQueueJob = id
            if let job = audiobookQueue.jobs.first(where: { $0.id == id }) { loadBook(job.source, chapterIDs: job.chapterIDs, queueID: id) }
        }
        refreshUsage()
        queueObservation = audiobookQueue.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var busy: Bool { isEstimating || isLoading || isCombining || loadingAPIVoices || isExporting || downloadInProgress || audiobookQueue.isRunning }
    var canSelectQueue: Bool { !isCombining && !isEstimating && !loadingAPIVoices && !isExporting && !downloadInProgress && !audiobookQueue.isRunning }
    var selectedWordCount: Int {
        book?.chapters.filter { selectedChapters.contains($0.id) }.reduce(0) { $0 + $1.wordCount } ?? 0
    }
    var estimatedDuration: String {
        let minutes = Int((Double(selectedWordCount) / max(1, provider == .system ? rate : 175 * apiSpeed)).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    var currentChapter: BookChapter? {
        book?.chapters.first(where: { $0.id == focusedChapter }) ?? book?.chapters.first
    }
    var filteredVoices: [SystemVoice] {
        voices.filter { $0.id == voice || voiceSearch.isEmpty || $0.label.localizedCaseInsensitiveContains(voiceSearch) }
    }
    var canExport: Bool { book != nil && !selectedChapters.isEmpty && narrationReady && ffmpeg != nil && !busy }

    func loadVoices() async {
        do {
            voices = try await SpeechTools.voices()
            if !voices.contains(where: { $0.name == voice }) {
                voice = SystemVoice.preferredName(in: voices)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    var canStartQueue: Bool { audiobookQueue.queuedCount > 0 && narrationReady && ffmpeg != nil && !busy }

    func chooseQueuedEPUBs() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add EPUBs"
        panel.message = "Select all the EPUBs you want to turn into audiobooks."
        guard panel.runModal() == .OK else { return }
        addToAudiobookQueue(panel.urls)
    }

    func addToAudiobookQueue(_ urls: [URL]) {
        guard !busy else { return }
        if audiobookQueue.add(urls) > 0 { selectedQueueJob = audiobookQueue.jobs.last?.id }
        stage = 1
    }

    func queueCurrentBook() {
        guard !busy, let book, !selectedChapters.isEmpty else { return }
        if audiobookQueue.add([book.source], chapterIDs: selectedChapters) > 0 {
            selectedQueueJob = audiobookQueue.jobs.last?.id
        }
    }

    func chooseAudiobookFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = audiobookFolder
        panel.prompt = "Save Audiobooks Here"
        panel.message = "Each queued EPUB will create its own audiobook here."
        if panel.runModal() == .OK, let folder = panel.url { audiobookFolder = folder }
    }

    func startAudiobookQueue() {
        guard canStartQueue, let ffmpeg else { return }
        if audiobookFolder == nil { chooseAudiobookFolder() }
        guard let folder = audiobookFolder else { return }
        stopPreview()
        do {
            let settings = BatchNarrationSettings(voice: voice, wordsPerMinute: Int(rate), bitrate: bitrate, mode: mode, ffmpeg: ffmpeg,
                api: try apiSettings(), usage: usageLedger, budget: try budget(), budgets: try queuedBudgets())
            try audiobookQueue.start(settings: settings, folder: folder, keyResolver: APIKeyStore.read)
        } catch { errorMessage = error.localizedDescription }
    }

    func clearCompletedAudiobooks() {
        audiobookQueue.clearFinished()
        if !audiobookQueue.jobs.contains(where: { $0.id == selectedQueueJob }) {
            selectedQueueJob = audiobookQueue.jobs.first?.id
        }
    }

    func revealQueuedAudiobook() {
        guard let output = audiobookQueue.jobs.first(where: { $0.id == selectedQueueJob })?.output else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    func chooseEPUB() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open EPUB"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadBook(url)
    }

    func loadBook(_ url: URL, chapterIDs: Set<String>? = nil, queueID: UUID? = nil) {
        guard !isExporting, !downloadInProgress, !isCombining, !audiobookQueue.isRunning else { return }
        if queueID == nil { selectedQueueJob = nil }
        stopPreview()
        loadTask?.cancel()
        let generation = UUID(); loadGeneration = generation
        isLoading = true; book = nil; selectedChapters = []; focusedChapter = nil
        exportedURL = nil; status = "Reading EPUB…"
        loadTask = Task {
            do {
                let loaded = try await EPUBLibrary.shared.read(url)
                try Task.checkCancellation()
                guard generation == loadGeneration else { return }
                applyBook(loaded, chapterIDs: chapterIDs)
                if let queueID { audiobookQueue.updateMetadata(queueID, book: loaded) }
            } catch is CancellationError {} catch {
                guard generation == loadGeneration else { return }
                errorMessage = error.localizedDescription; status = "This EPUB could not be opened."
            }
            if generation == loadGeneration { isLoading = false; loadTask = nil }
        }
    }

    private func applyBook(_ loaded: EPUBBook, chapterIDs: Set<String>? = nil) {
        book = loaded; stage = 1; exportedURL = nil
        selectedChapters = chapterIDs ?? Set(loaded.chapters.filter(\.includedByDefault).map(\.id))
        focusedChapter = loaded.chapters.first?.id; status = "Ready to narrate."
    }

    var narrationReady: Bool {
        provider == .system ? !voice.isEmpty : hasAPIKey && !(provider == .openAI ? openAIVoice : elevenVoice).isEmpty
    }
    func apiSettings() throws -> APINarration? {
        guard provider != .system else { return nil }
        let settings = APINarration(provider: provider, model: provider == .openAI ? openAIModel : elevenModel,
            voice: provider == .openAI ? openAIVoice : elevenVoice, speed: apiSpeed,
            instructions: instructions, apiKey: try APIKeyStore.read(provider))
        try settings.validate()
        return settings
    }
    func refreshKeyStatus() {
        hasAPIKey = provider != .system && APIKeyStore.contains(provider)
        apiKeyStatus = hasAPIKey ? "API key saved in Keychain." : "No API key saved."
        apiSpeed = min(provider.speedRange.upperBound, max(provider.speedRange.lowerBound, apiSpeed))
    }
    func saveAPIKey() {
        do { try APIKeyStore.save(apiKeyDraft, provider: provider); apiKeyDraft = ""; refreshKeyStatus() }
        catch { errorMessage = error.localizedDescription }
    }
    func removeAPIKey() {
        do { try APIKeyStore.remove(provider); refreshKeyStatus() }
        catch { errorMessage = error.localizedDescription }
    }
    func loadAPIVoices() {
        guard !busy, provider == .elevenLabs else { return }
        do {
            let key = try APIKeyStore.read(provider)
            loadingAPIVoices = true
            Task {
                defer { loadingAPIVoices = false }
                do { apiVoices = try await APISpeechClient().elevenLabsVoices(apiKey: key) }
                catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    var seriesJobs: [AudiobookJob] { audiobookQueue.jobs.filter { seriesJobIDs.contains($0.id) && $0.state == .queued } }
    func combineSeries() {
        guard !busy, seriesJobs.count >= 2 else { return }
        let jobs = seriesJobs
        let title = seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { errorMessage = "Enter a title for the combined series."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.nameFieldStringValue = FileNames.safe(title) + ".epub"
        panel.message = "Save a new EPUB containing the selected books in queue order. The combined book will replace those entries in the queue."
        panel.prompt = "Combine EPUBs"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isCombining = true; stopPreview(); status = "Combining series…"
        combineTask = Task {
            do {
                let combined = try await Task.detached(priority: .userInitiated) {
                    try EPUBMerger.combine(jobs.map(\.source), title: title, destination: destination)
                }.value
                audiobookQueue.replaceWithCombined(Set(jobs.map(\.id)), source: destination)
                seriesJobIDs = []; isCombining = false
                selectedQueueJob = audiobookQueue.jobs.first(where: { $0.source == destination })?.id
                applyBook(combined)
                status = "Combined EPUB saved and queued."
            } catch { errorMessage = error.localizedDescription; isCombining = false; status = "Series could not be combined." }
            combineTask = nil
        }
    }

    func toggleChapter(_ id: String, included: Bool) {
        if included { selectedChapters.insert(id) } else { selectedChapters.remove(id) }
        exportedURL = nil
    }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.message = "Select the FFmpeg executable used to encode MP3 files."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await SpeechTools.verifyFFmpeg(url, runner: ProcessRunner())
                ffmpeg = url
                UserDefaults.standard.set(url.path, forKey: "ffmpegPath")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func preview() {
        if isPreviewing { stopPreview(); return }
        guard narrationReady, !busy else { return }
        let text = currentChapter?.text ?? "Welcome. This is a preview of the voice for your audiobook. Choose a speaking speed that feels comfortable to you."
        let sample = SpeechText.preview(text, provider: provider)
        let api: APINarration?
        do { api = try apiSettings(); _ = try budget() } catch { errorMessage = error.localizedDescription; return }
        let runner = ProcessRunner()
        previewRunner = runner
        isPreviewing = true
        let chosenVoice = voice
        let chosenRate = Int(rate)
        previewTask = Task {
            do {
                if let api {
                    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("tts-preview-\(UUID().uuidString)." + (api.provider == .openAI ? "wav" : "mp3"))
                    defer { try? FileManager.default.removeItem(at: audio) }
                    try await APISpeechClient().synthesize(text: sample, settings: api, destination: audio, usage: usageLedger, budget: try budget())
                    try runner.checkCancellation()
                    _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/afplay"), arguments: [audio.path])
                } else {
                    _ = try await runner.run(SpeechTools.say, arguments: ["-v", chosenVoice, "-r", String(chosenRate), "--", sample])
                }
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
            refreshUsage()
            isPreviewing = false
            previewRunner = nil
            previewTask = nil
        }
    }

    func stopPreview() {
        previewRunner?.cancel()
        previewTask?.cancel()
        // Keep isPreviewing set until the process exits; this prevents overlapping previews.
    }

    func chooseDestinationAndExport() {
        guard canExport, let book, let ffmpeg else { return }
        let api: APINarration?
        do { api = try apiSettings(); _ = try budget() } catch { errorMessage = error.localizedDescription; return }
        let destination: URL
        if mode != .chapters {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: mode.fileExtension) ?? .audio]
            panel.nameFieldStringValue = FileNames.safe(book.title) + "." + mode.fileExtension
            panel.prompt = "Create Audiobook"
            panel.message = "Choose a new filename for your audiobook."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "A new audiobook folder will be created here, containing numbered chapter MP3s."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let name = FileNames.safe(book.title)
            var candidate = folder.appendingPathComponent(name, isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(name) (\(suffix))", isDirectory: true)
                suffix += 1
            }
            destination = candidate
        }
        stopPreview()
        let options = ExportOptions(voice: voice, wordsPerMinute: Int(rate), bitrate: bitrate,
            mode: mode, chapterIDs: selectedChapters, ffmpeg: ffmpeg, api: api,
            checkpoint: singleCheckpoint(book), usage: usageLedger, budget: try? budget())
        let runner = ProcessRunner()
        exportRunner = runner
        isExporting = true
        exportedURL = nil
        progress = 0
        status = "Preparing audiobook…"
        exportTask = Task { [self] in
            do {
                let result = try await AudiobookExporter.export(book: book, options: options, destination: destination, runner: runner) { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.progress = update.fraction
                        self?.status = update.message
                    }
                }
                exportedURL = result
                progress = 1
                status = "Your audiobook is ready."
            } catch is CancellationError {
                status = "Export cancelled."
                progress = 0
            } catch {
                errorMessage = error.localizedDescription
                status = "Export failed."
                progress = 0
            }
            refreshUsage()
            isExporting = false
            exportRunner = nil
            exportTask = nil
        }
    }

    func cancelExport() {
        guard isExporting else { return }
        status = "Cancelling…"
        exportRunner?.cancel()
        exportTask?.cancel()
    }

    func revealExport() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }

    func shutdown() async {
        loadTask?.cancel()
        stopPreview()
        cancelExport()
        await audiobookQueue.shutdown()
        // Finish the validated EPUB publication before allowing the app to quit.
        await combineTask?.value
        await exportTask?.value
        await previewTask?.value
    }
}
