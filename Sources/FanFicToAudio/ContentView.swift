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
                    narrationSettings
                    outputSettings
                    APIUsageView(model: model)
                    AudiobookQueueView(model: model, queue: model.audiobookQueue)
                    if let book = model.book {
                        Divider()
                        Text("Open book").font(.headline)
                        bookSummary(book).id(book.source)
                        chapterPreview.id(book.source.path + (model.focusedChapter ?? ""))
                        exportSection
                        if !book.warnings.isEmpty {
                            Label(book.warnings.joined(separator: "\n"), systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else {
                        HStack {
                            Text("Open a single EPUB to review its text and choose individual sections.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open EPUB…", action: model.chooseEPUB).disabled(model.busy)
                        }
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

    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR STORY, OUT LOUD").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(accent)
                Text("Create your audiobooks").font(.system(size: 32, weight: .semibold, design: .serif))
                Text("Choose a speech provider, add EPUBs, and create your audiobooks.").foregroundStyle(.secondary)
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
            Label(model.provider == .system ? "Narration on your Mac" : "AI narration via \(model.provider.rawValue)", systemImage: model.provider == .system ? "desktopcomputer" : "waveform").font(.caption).foregroundStyle(.secondary).padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var outputSettings: some View {
        HStack(spacing: 24) {
            Picker("Output", selection: $model.mode) { ForEach(ExportMode.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Quality", selection: $model.bitrate) {
                Text("64 kbps").tag(64)
                Text("96 kbps").tag(96)
                Text("128 kbps").tag(128)
                Text("192 kbps").tag(192)
            }.frame(width: 160)
        }.disabled(model.busy)
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

    private var narrationSettings: some View { NarrationSettingsView(model: model) }

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
            Text("Export open book").font(.headline)
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
        guard !model.busy, !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url, url.pathExtension.lowercased() == "epub" { urls.append(url) }
            }
            if urls.isEmpty { model.errorMessage = "Choose files with the .epub extension." }
            else { model.addToAudiobookQueue(urls) }
        }
        return true
    }
}
