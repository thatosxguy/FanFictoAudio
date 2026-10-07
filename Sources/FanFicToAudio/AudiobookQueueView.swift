import SwiftUI
import UniformTypeIdentifiers
import AudiobookCore

struct AudiobookQueueView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: AudiobookQueue
    private let accent = Color(red: 0.24, green: 0.43, blue: 0.48)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Audiobook queue").font(.headline)
                Spacer()
                if model.book != nil {
                    Button("Add Open Book", action: model.queueCurrentBook)
                        .disabled(model.busy || model.selectedChapters.isEmpty)
                }
                Button("Add EPUBs…", action: model.chooseQueuedEPUBs).disabled(model.busy)
            }
            Text("The queue is saved automatically. New books use the settings above; you can save separate settings and sections for each selected book.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save audiobooks to").font(.caption.weight(.medium))
                    Text(model.audiobookFolder?.path ?? "Choose an output folder when starting the queue.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).id(model.audiobookFolder)
                }
                Spacer()
                if model.audiobookFolder != nil {
                    Button("Clear Folder") { model.audiobookFolder = nil }.disabled(model.busy)
                }
                Button("Choose Folder…", action: model.chooseAudiobookFolder).disabled(model.busy)
            }
            if queue.jobs.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "books.vertical").font(.system(size: 30)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Make audiobooks in bulk").font(.callout.weight(.medium))
                        Text("Each book gets its own MP3, M4B, or chapter folder. Existing audiobooks are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(queue.jobs.enumerated()), id: \.element.id) { index, job in
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("Include \(job.title) in combined series", isOn: Binding(
                                    get: { model.seriesJobIDs.contains(job.id) },
                                    set: { if $0 { model.seriesJobIDs.insert(job.id) } else { model.seriesJobIDs.remove(job.id) } }))
                                    .labelsHidden().toggleStyle(.checkbox).padding(.top, 14)
                                    .disabled(model.busy || job.state != .queued)
                                Button { model.selectedQueueJob = job.id } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(job.title).font(.callout.weight(.medium)).lineLimit(2)
                                        if !job.author.isEmpty { Text(job.author).font(.caption).foregroundStyle(.secondary) }
                                        if let preset = job.narration {
                                            Text("\(preset.provider.rawValue) · \(preset.provider == .system ? preset.voice : preset.apiVoice) · \(preset.mode.rawValue)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(job.message).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary).lineLimit(3)
                                        if job.state == .running { ProgressView(value: job.progress) }
                                    }
                                    Spacer(minLength: 8)
                                    Text(job.state.rawValue).font(.caption.weight(.medium))
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(accent.opacity(0.1), in: Capsule())
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedQueueJob == job.id ? accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
                                }.buttonStyle(.plain).disabled(!model.canSelectQueue)
                                    .onDrag { NSItemProvider(object: job.id.uuidString as NSString) }
                                    .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                        guard !model.busy, let provider = providers.first else { return false }
                                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
                                            Task { @MainActor in if !model.busy { queue.move(id, before: job.id) } }
                                        }
                                        return true
                                    }
                            }
                        }
                    }

                }.frame(maxHeight: 240)
                if let job = queue.jobs.first(where: { $0.id == model.selectedQueueJob }) {
                    HStack {
                        Button { queue.move(job.id, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                            .disabled(model.busy || !queue.canMove(job.id, by: -1))
                        Button { queue.move(job.id, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                            .disabled(model.busy || !queue.canMove(job.id, by: 1))
                        if job.output != nil { Button("Show Audiobook in Finder", action: model.revealQueuedAudiobook) }
                        if [.failed, .cancelled].contains(job.state) {
                            Button("Retry Selected") { queue.retry(job.id) }.disabled(model.busy)
                        }
                        Spacer()
                        Button("Remove Selected") {
                            queue.remove(job.id); model.seriesJobIDs.remove(job.id)
                            model.selectedQueueJob = queue.jobs.first?.id
                        }.disabled(model.busy)
                        Button("Clear Completed", action: model.clearCompletedAudiobooks).disabled(model.busy)
                    }
                    if job.state != .done {
                        HStack {
                            Button("Save Current Settings & Sections for Selected Book", action: model.saveSelectedJobSettings)
                                .disabled(model.busy || model.book?.source != job.source || model.selectedChapters.isEmpty)
                            Button("Discard Saved Passages") { queue.discardCheckpoint(job.id) }.disabled(model.busy)
                        }
                    }
                }
            }
            if queue.queuedCount >= 2 || !model.seriesJobs.isEmpty {
                Divider()
                HStack {
                    Text("Combine a series").font(.callout.weight(.medium))
                    Spacer()
                    Button("Select Waiting EPUBs") { model.seriesJobIDs = Set(queue.jobs.filter { $0.state == .queued }.map(\.id)) }.disabled(model.busy)
                    Button("Clear Selection") { model.seriesJobIDs = [] }.disabled(model.busy)
                }
                Text("Check the books to combine, move them into reading order, and give the series a title. The saved EPUB preserves chapters, images, and styles; its queue entry creates the series audiobook.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Series title", text: $model.seriesTitle).textFieldStyle(.roundedBorder)
                    Text("\(model.seriesJobs.count) books").font(.caption).foregroundStyle(.secondary)
                    Button(model.isCombining ? "Combining…" : "Combine Selected EPUBs…", action: model.combineSeries)
                        .disabled(model.busy || model.seriesJobs.count < 2 || model.seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.disabled(model.busy)
            }
            if queue.isRunning { ProgressView(value: queue.batchProgress) }
            if let error = queue.persistenceError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(queue.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if queue.isRunning {
                    Button("Cancel & Pause Queue", action: queue.cancelAndPause)
                } else {
                    Button(model.audiobookFolder == nil ? "Create Queued Audiobooks…" : "Start Queue", action: model.startAudiobookQueue)
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStartQueue)
                }
            }
            if model.ffmpeg == nil {
                HStack {
                    Text("Select FFmpeg to enable audiobook conversion.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose FFmpeg…", action: model.chooseFFmpeg).disabled(model.busy)
                }
            }
            Text("Select a row to open its EPUB, or drag rows into reading order. During conversion, the open book follows the active job. Retry resumes completed passages when the content and settings match. Removing a book discards its saved passages.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
