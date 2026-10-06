import SwiftUI
import AudiobookCore

struct APIUsageView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        DisclosureGroup("AI usage and budget") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Character limit (optional)", text: $model.aiCharacterLimit)
                TextField("Estimated cost limit in USD (optional)", text: $model.aiCostLimit)
            }.textFieldStyle(.roundedBorder).disabled(model.busy || model.isPreviewing)
            if model.provider != .system {
                HStack {
                    TextField("Estimated all-in USD rate", text: $model.aiPrice).textFieldStyle(.roundedBorder)
                    Picker("Per", selection: $model.aiPriceBasis) {
                        ForEach(APIPriceBasis.allCases) { Text($0.rawValue).tag($0) }
                    }
                }.disabled(model.busy || model.isPreviewing)
                if !model.openBookEstimate.isEmpty { Text("Open book: " + model.openBookEstimate).font(.caption) }
            }
            HStack {
                Button("Estimate Queued AI Usage", action: model.calculateQueueEstimate).disabled(model.busy)
                Spacer()
                Button("Reset Usage", action: model.resetUsage).disabled(model.busy || model.isPreviewing)
            }
            if !model.queueEstimate.isEmpty { Text(model.queueEstimate).font(.caption).textSelection(.enabled) }
            Text("Since \(model.usageSummary.since.formatted(date: .abbreviated, time: .shortened)): \(model.usageSummary.requests) speech attempts · \(model.usageSummary.characters.formatted()) characters · \(String(format: "estimated $%.3f", model.usageSummary.estimatedCost))" + (model.usageSummary.unpricedRequests > 0 ? " · \(model.usageSummary.unpricedRequests) unpriced attempts" : ""))
                .font(.caption).foregroundStyle(.secondary)
            Text("Enter the rate for your provider, model, and plan; it is saved per model. Include input and audio charges in your all-in estimate. Token and listening-time estimates are approximate. Limits count previews, retries, and failed attempts since Reset Usage; they stop before sending the next passage. Provider invoices may differ, and resumed passages are included in the full-book estimate.")
                .font(.caption2).foregroundStyle(.secondary)
          }.padding(.top, 10)
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .task {
                while !Task.isCancelled {
                    model.refreshUsage()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}
