import SwiftUI
import UniformTypeIdentifiers
import AudiobookCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    private let accent = Color(red: 0.24, green: 0.43, blue: 0.48)

    var body: some View {
        HStack(spacing: 0) {
            chapterSidebar.frame(width: 290)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let book = model.book {
                        bookSummary(book)
                        narrationSettings
                        chapterPreview
                        exportSection
                        if !book.warnings.isEmpty {
                            Label(book.warnings.joined(separator: "\n"), systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else {
                        emptyState
                        narrationSettings
                    }
                }
                .padding(32)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTarget, perform: acceptDrop)
        .overlay {
            if model.isDropTarget {
                RoundedRectangle(cornerRadius: 16).stroke(accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .alert("Unable to complete this action", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .toolbar {
            ToolbarItem {
                Button(action: model.chooseEPUB) { Label("Open EPUB", systemImage: "plus") }.disabled(model.busy)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR BOOK, OUT LOUD").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(accent)
                Text("EPUB to MP3").font(.system(size: 32, weight: .semibold, design: .serif))
                Text("Create an audiobook with the voices on your Mac.").foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "book.and.wrench").font(.system(size: 30)).foregroundStyle(accent).padding(10)
                .accessibilityHidden(true)
        }
    }

    private var chapterSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Reading order").font(.headline)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }.padding(20)
            if let book = model.book {
                HStack {
                    Text("\(model.selectedChapters.count) of \(book.chapters.count) sections").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Select All") { model.selectedChapters = Set(book.chapters.map(\.id)) }
                        Button("Select Reading Order") { model.selectedChapters = Set(book.chapters.filter(\.includedByDefault).map(\.id)) }
                        Button("Deselect All") { model.selectedChapters = [] }
                    } label: { Image(systemName: "checklist") }.menuStyle(.borderlessButton).frame(width: 28)
                }.padding(.horizontal, 20).padding(.bottom, 12).disabled(model.busy)
                List(selection: $model.focusedChapter) {
                    ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("Include \(chapter.title)", isOn: Binding(
                                get: { model.selectedChapters.contains(chapter.id) },
                                set: { model.toggleChapter(chapter.id, included: $0) }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapter.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text("\(index + 1) · \(chapter.wordCount.formatted()) words").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(chapter.id)
                    }
                }.listStyle(.sidebar)
                Text("Sections follow the EPUB spine. Navigation and non-linear extras start unchecked.")
                    .font(.caption2).foregroundStyle(.secondary).padding(20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed").font(.system(size: 35)).foregroundStyle(.tertiary)
                    Text("Your book’s sections\nwill appear here.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Label("Processed on your Mac", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary).padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
            Text(model.isLoading ? "Reading your book…" : "Drop an EPUB here").font(.title2.weight(.medium))
            Text("Or choose a book to see its chapters and preview the narration.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose EPUB…", action: model.chooseEPUB).buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            Text("Text-based EPUB 2 and 3 · DRM-free").font(.caption).foregroundStyle(.secondary)
        }
        .padding(32).frame(maxWidth: .infinity)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func bookSummary(_ book: EPUBBook) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(accent.gradient)
                Image(systemName: "book.closed.fill").font(.system(size: 32)).foregroundStyle(.white.opacity(0.85))
            }.frame(width: 68, height: 88).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                if !book.author.isEmpty { Text(book.author).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack(spacing: 16) {
                    Label("\(model.selectedWordCount.formatted()) words", systemImage: "text.alignleft")
                    Label("About \(model.estimatedDuration) of audio", systemImage: "clock")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var narrationSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Narration").font(.headline)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Voice").font(.caption).foregroundStyle(.secondary)
                    Picker("Voice", selection: $model.voice) {
                        if model.voices.isEmpty { Text("Loading voices…").tag("") }
                        ForEach(model.filteredVoices) { voice in Text(voice.label).tag(voice.name) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                Button(action: model.preview) {
                    Label(model.isPreviewing ? "Stop" : "Preview", systemImage: model.isPreviewing ? "stop.fill" : "play.fill")
                }.disabled(model.voice.isEmpty || model.busy)
            }
            TextField("Filter voices by name or language", text: $model.voiceSearch).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Text("Speed").font(.callout)
                Slider(value: $model.rate, in: SpeechRate.sliderRange, step: 5).accessibilityLabel("Speaking speed in words per minute")
                Text("\(Int(model.rate)) wpm").font(.system(.callout, design: .monospaced)).frame(width: 88, alignment: .trailing)
            }
            Text("Preview reads the selected section. Download more voices in macOS System Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .disabled(model.busy)
        .onChange(of: model.voice) { _, _ in model.stopPreview() }
        .onChange(of: model.rate) { _, _ in model.stopPreview() }
    }

    @ViewBuilder private var chapterPreview: some View {
        if let chapter = model.currentChapter {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Text preview").font(.headline)
                    Spacer()
                    Text(chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ScrollView {
                    Text(String(chapter.text.prefix(8000))).font(.system(size: 14, design: .serif)).lineSpacing(5)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 125)
                if chapter.text.count > 8000 { Text("Showing the first part of this section. Export includes its full text.").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text("Export").font(.headline)
            HStack(spacing: 24) {
                Picker("Output", selection: $model.mode) { ForEach(ExportMode.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Quality", selection: $model.bitrate) {
                    Text("64 kbps").tag(64)
                    Text("96 kbps").tag(96)
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                }.frame(width: 160)
            }.disabled(model.busy)
            if model.ffmpeg == nil {
                HStack {
                    Label("Select FFmpeg to enable MP3 export.", systemImage: "info.circle").font(.callout)
                    Spacer()
                    Button("Choose FFmpeg…", action: model.chooseFFmpeg)
                }
            }
            if model.isExporting {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: model.cancelExport)
                }
            } else {
                HStack {
                    if model.exportedURL != nil {
                        Label("Audiobook ready", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                        Button("Show in Finder", action: model.revealExport)
                    } else { Text(model.status).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Create Audiobook…", action: model.chooseDestinationAndExport)
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canExport)
                }
            }
            Text("Estimated length is the listening time. Conversion time depends on the voice and book. Your Mac stays awake while exporting.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy, let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                if url.pathExtension.lowercased() == "epub" { model.loadBook(url) }
                else { model.errorMessage = "Choose a file with the .epub extension." }
            }
        }
        return true
    }
}
