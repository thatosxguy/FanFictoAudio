import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AudiobookCore

@MainActor
final class AppModel: ObservableObject {
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
    @Published var mode: ExportMode = .single
    @Published var ffmpeg = SpeechTools.findFFmpeg()
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var isPreviewing = false
    @Published var progress = 0.0
    @Published var status = "Choose an EPUB to begin."
    @Published var errorMessage: String?
    @Published var exportedURL: URL?
    @Published var voiceSearch = ""
    @Published var isDropTarget = false
    private var exportTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var exportRunner: ProcessRunner?
    private var previewRunner: ProcessRunner?

    var busy: Bool { isLoading || isExporting }
    var selectedWordCount: Int {
        book?.chapters.filter { selectedChapters.contains($0.id) }.reduce(0) { $0 + $1.wordCount } ?? 0
    }
    var estimatedDuration: String {
        let minutes = Int((Double(selectedWordCount) / max(1, rate)).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    var currentChapter: BookChapter? {
        book?.chapters.first(where: { $0.id == focusedChapter }) ?? book?.chapters.first
    }
    var filteredVoices: [SystemVoice] {
        voices.filter { $0.id == voice || voiceSearch.isEmpty || $0.label.localizedCaseInsensitiveContains(voiceSearch) }
    }
    var canExport: Bool { book != nil && !selectedChapters.isEmpty && !voice.isEmpty && ffmpeg != nil && !busy }

    func loadVoices() async {
        do {
            voices = try await SpeechTools.voices()
            if !voices.contains(where: { $0.name == voice }) {
                voice = voices.first(where: { $0.name == "Samantha" })?.name ?? voices.first?.name ?? ""
            }
        } catch { errorMessage = error.localizedDescription }
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

    func loadBook(_ url: URL) {
        guard !busy else { return }
        stopPreview()
        isLoading = true
        exportedURL = nil
        status = "Reading EPUB…"
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try EPUBReader.read(url) }.value
                book = loaded
                selectedChapters = Set(loaded.chapters.filter(\.includedByDefault).map(\.id))
                focusedChapter = loaded.chapters.first?.id
                status = "Ready to narrate."
            } catch {
                errorMessage = error.localizedDescription
                status = book == nil ? "Choose an EPUB to begin." : "Ready to narrate."
            }
            isLoading = false
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
        guard !voice.isEmpty, !busy else { return }
        let text = currentChapter?.text ?? "Welcome. This is a preview of the voice for your audiobook. Choose a speaking speed that feels comfortable to you."
        // Use a short sample, preferring a complete sentence near the cutoff.
        let prefix = String(text.prefix(550))
        let sample: String
        if let end = prefix.range(of: #"[.!?](?:\s|$)"#, options: [.regularExpression, .backwards]) {
            sample = String(prefix[..<end.upperBound])
        } else { sample = prefix }
        let runner = ProcessRunner()
        previewRunner = runner
        isPreviewing = true
        let chosenVoice = voice
        let chosenRate = Int(rate)
        previewTask = Task {
            do {
                // -- terminates options, so text beginning with a dash is spoken safely.
                _ = try await runner.run(SpeechTools.say, arguments: ["-v", chosenVoice, "-r", String(chosenRate), "--", sample])
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
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
        let destination: URL
        if mode == .single {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mp3]
            panel.nameFieldStringValue = FileNames.safe(book.title) + ".mp3"
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
            mode: mode, chapterIDs: selectedChapters, ffmpeg: ffmpeg)
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
            isExporting = false
            exportRunner = nil
            exportTask = nil
        }
    }

    func cancelExport() {
        status = "Cancelling…"
        exportRunner?.cancel()
        exportTask?.cancel()
    }

    func revealExport() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }

    func shutdown() async {
        stopPreview()
        cancelExport()
        await exportTask?.value
        await previewTask?.value
    }
}
