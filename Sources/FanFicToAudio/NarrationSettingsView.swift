import SwiftUI
import AudiobookCore

struct NarrationSettingsView: View {
    @ObservedObject var model: AppModel
    private var openAIVoices: [String] {
        let all = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse", "marin", "cedar"]
        return model.openAIModel.hasPrefix("tts-1") ? all.filter { !["ballad", "verse", "marin", "cedar"].contains($0) } : all
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Narration").font(.headline)
            Picker("Speech provider", selection: $model.provider) {
                ForEach(NarrationProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.provider == .system {
                HStack(spacing: 12) {
                    Picker("Voice", selection: $model.voice) {
                        if model.voices.isEmpty { Text("Loading voices…").tag("") }
                        ForEach(model.filteredVoices) { Text($0.label).tag($0.name) }
                    }
                    previewButton
                }
                TextField("Filter voices by name or language", text: $model.voiceSearch).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Speed")
                    Slider(value: $model.rate, in: SpeechRate.sliderRange, step: 5).accessibilityLabel("Speaking speed in words per minute")
                    Text("\(Int(model.rate)) wpm").monospacedDigit().frame(width: 88, alignment: .trailing)
                }
                Text("Preview reads the selected section, or a short sample when no book is open. More voices are available in macOS System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                apiControls
                HStack {
                    Text("Speed")
                    Slider(value: $model.apiSpeed, in: model.provider.speedRange, step: 0.05).accessibilityLabel("API speech speed multiplier")
                    Text(String(format: "%.2f×", model.apiSpeed)).monospacedDigit().frame(width: 65)
                    previewButton
                }
                HStack {
                    SecureField("API key for \(model.provider.rawValue)", text: $model.apiKeyDraft).textFieldStyle(.roundedBorder)
                    Button("Save Key", action: model.saveAPIKey).disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasAPIKey { Button("Remove Key", action: model.removeAPIKey) }
                }
                Text(model.apiKeyStatus).font(.caption).foregroundStyle(.secondary)
                Text("AI-generated voice. Preview and conversion send book text to \(model.provider.rawValue); API usage is billed by that provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.busy)
            .onChange(of: model.voice) { _, _ in model.stopPreview() }
            .onChange(of: model.rate) { _, _ in model.stopPreview() }
            .onChange(of: model.openAIVoice) { _, _ in model.stopPreview() }
            .onChange(of: model.elevenVoice) { _, _ in model.stopPreview() }
            .onChange(of: model.apiSpeed) { _, _ in model.stopPreview() }
    }
    private var previewButton: some View {
        Button(action: model.preview) {
            Label(model.isPreviewing ? "Stop" : "Preview", systemImage: model.isPreviewing ? "stop.fill" : "play.fill")
        }.disabled(!model.narrationReady)
    }
    @ViewBuilder private var apiControls: some View {
        if model.provider == .openAI {
            HStack {
                TextField("Model", text: $model.openAIModel).textFieldStyle(.roundedBorder)
                Menu("Models") {
                    ForEach(["gpt-4o-mini-tts", "tts-1", "tts-1-hd"], id: \.self) { name in Button(name) { model.openAIModel = name } }
                }.frame(width: 95)
                Picker("Voice", selection: $model.openAIVoice) {
                    ForEach(openAIVoices, id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
            }
            if !model.openAIModel.hasPrefix("tts-1") {
                TextField("Narration style (optional), e.g. warm and expressive", text: $model.instructions).textFieldStyle(.roundedBorder)
            }
        } else {
            HStack {
                TextField("Model", text: $model.elevenModel).textFieldStyle(.roundedBorder)
                Menu("Models") {
                    ForEach(["eleven_multilingual_v2", "eleven_flash_v2_5", "eleven_turbo_v2_5", "eleven_v3"], id: \.self) { name in Button(name) { model.elevenModel = name } }
                }.frame(width: 95)
                Button(model.loadingAPIVoices ? "Loading…" : "Load Voices", action: model.loadAPIVoices).disabled(!model.hasAPIKey)
            }
            HStack {
                TextField("Voice ID from your ElevenLabs library", text: $model.elevenVoice).textFieldStyle(.roundedBorder)
                if !model.apiVoices.isEmpty {
                    Picker("Library voice", selection: $model.elevenVoice) {
                        Text("Enter voice ID").tag(model.apiVoices.contains(where: { $0.id == model.elevenVoice }) ? "" : model.elevenVoice)
                        ForEach(model.apiVoices) { Text($0.name).tag($0.id) }
                    }.frame(width: 235)
                }
            }
        }
    }
}
