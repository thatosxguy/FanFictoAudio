import SwiftUI

struct WorkflowView: View {
    @ObservedObject var audio: AppModel
    @ObservedObject var download: DownloadModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label("FanFic to Audio", systemImage: "book.fill").font(.headline)
                Spacer()
                Picker("Workflow", selection: $audio.stage) {
                    Text("1 · Download EPUB").tag(0)
                    Text("2 · Create Audiobook").tag(1)
                }.pickerStyle(.segmented).frame(width: 370)
                Spacer()
                Button("Open EPUB…") { audio.chooseEPUB() }.disabled(audio.busy)
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if audio.stage == 0 {
                DownloadView(model: download) { url in open(url) }.disabled(audio.isExporting || audio.isLoading || audio.audiobookQueue.isRunning)
            } else {
                ContentView(model: audio)
            }
        }
        .onChange(of: download.isRunning) { _, value in
            audio.downloadInProgress = value
            if value { audio.stopPreview() }
        }
        .onChange(of: download.readyURL) { _, url in
            audio.downloadInProgress = download.isRunning
            if let url { open(url) }
        }
    }

    private func open(_ url: URL) {
        guard !audio.busy else { return }
        audio.stage = 1
        audio.loadBook(url)
    }
}
