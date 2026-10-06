import Foundation
import Testing
import AudiobookCore
@testable import FanFicToAudio

@MainActor struct SelectionTests {
    @Test func queueSelectionCannotChangeDuringIndividualExportOrDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root)
        let first = root.appendingPathComponent("first.epub")
        let second = root.appendingPathComponent("second.epub")
        model.audiobookQueue.add([first, second])
        let firstID = model.audiobookQueue.jobs[0].id
        let secondID = model.audiobookQueue.jobs[1].id
        model.selectedQueueJob = firstID
        model.book = EPUBBook(title: "First", author: "", language: "en", chapters: [], source: first)
        model.isExporting = true
        #expect(!model.canSelectQueue)
        model.selectedQueueJob = secondID
        #expect(model.selectedQueueJob == firstID)
        #expect(model.book?.source == first)
        model.isExporting = false; model.downloadInProgress = true
        model.selectedQueueJob = secondID
        #expect(model.selectedQueueJob == firstID)
        model.downloadInProgress = false
        #expect(model.canSelectQueue)
        model.selectedQueueJob = secondID
        #expect(model.selectedQueueJob == secondID)
        await model.shutdown()
    }
}
