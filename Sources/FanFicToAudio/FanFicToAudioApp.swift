import SwiftUI
import AppKit
import AudiobookCore

@main
struct FanFicToAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var download = DownloadModel()
    var body: some Scene {
        Window("FanFic to Audio", id: "main") {
            WorkflowView(audio: model, download: download)
                .frame(minWidth: 1060, minHeight: 700)
                .task {
                    delegate.model = model
                    delegate.download = download
                    await model.loadVoices()
                }
                .onOpenURL { model.loadBook($0) }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open EPUB…", action: model.chooseEPUB).keyboardShortcut("o").disabled(model.busy)
                Button("Add EPUBs to Audiobook Queue…", action: model.chooseQueuedEPUBs)
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
            }
            CommandGroup(after: .importExport) {
                Button("Export Audiobook…", action: model.chooseDestinationAndExport)
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.canExport)
            }
        }
        Settings {
            VStack(alignment: .leading, spacing: 16) {
                Text("MP3 encoder").font(.title2.bold())
                Text("Speech uses the voices installed on your Mac. FFmpeg converts the resulting audio to MP3.")
                Text(model.ffmpeg?.path ?? "FFmpeg was not found.").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Choose FFmpeg…", action: model.chooseFFmpeg).disabled(model.busy)
                Link("FFmpeg installation options", destination: URL(string: "https://ffmpeg.org/download.html#build-mac")!)
                Divider()
                Text("Additional voices").font(.headline)
                Text("Download voices in System Settings → Accessibility → Read & Speak (called Spoken Content on earlier macOS versions). Then refresh the voice list.")
                Button("Refresh Voices") { Task { await model.loadVoices() } }.disabled(model.busy || model.isPreviewing)
            }
            .padding(24).frame(width: 470)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var download: DownloadModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await download?.shutdown()
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
