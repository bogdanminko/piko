import SwiftUI

struct MainView: View {
    @State private var processor = VideoProcessorVM()
    @State private var modelManager = ModelManagerVM()
    @State private var stylePreviews = StylePreviewsVM()

    var body: some View {
        NavigationSplitView {
            StylePickerView(processor: processor, previews: stylePreviews)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ModelPickerView(modelManager: modelManager)
            }
        }
        .task {
            async let models: Void = modelManager.loadModels()
            async let previews: Void = stylePreviews.load()
            _ = await (models, previews)
        }
        // Any subtitle setting changed after a completed run (sidebar or
        // preview screen): fast re-render from the cached transcription —
        // or an instant swap if that combination was already rendered.
        .onChange(of: processor.selectedStyle) { rerenderIfDone() }
        .onChange(of: processor.wordMode) { rerenderIfDone() }
        .onChange(of: processor.highlightColorHex) { rerenderIfDone() }
    }

    private func rerenderIfDone() {
        if case .done = processor.state {
            Task { await processor.reRender() }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch processor.state {
        case .idle:
            DropZoneView(processor: processor, modelManager: modelManager)

        case .processing(_, let percent, let message):
            ProcessingView(percent: percent, message: message)

        case .done:
            PreviewView(
                processor: processor,
                stylePreviews: stylePreviews,
                onReset: { processor.reset() }
            )

        case .error(let message):
            ErrorView(message: message, onRetry: { processor.reset() })
        }
    }
}

// MARK: - Drop Zone

struct DropZoneView: View {
    @Bindable var processor: VideoProcessorVM
    @Bindable var modelManager: ModelManagerVM

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let videoURL = processor.videoURL {
                // Video selected — show info and process button
                VStack(spacing: 16) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)

                    Text(videoURL.lastPathComponent)
                        .font(.title3.bold())

                    Text("Style: \(processor.selectedStyle.displayName)")
                        .foregroundStyle(.secondary)

                    Button("Generate Subtitles") {
                        Task {
                            await processor.processVideo(modelId: modelManager.selectedModelId)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(processor.isProcessing)

                    Button("Choose Different Video") {
                        processor.selectFile()
                    }
                    .controlSize(.small)
                }
            } else {
                // No video — drop zone
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("Drop Video Here")
                        .font(.title2.bold())

                    Text("or click to browse")
                        .foregroundStyle(.secondary)
                }
                .onTapGesture {
                    processor.selectFile()
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.quaternary)
                .padding()
        )
        .onDrop(of: [.movie, .fileURL], isTargeted: nil) { providers in
            processor.handleDrop(providers: providers)
        }
    }
}

// MARK: - Error View

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Error")
                .font(.title2.bold())

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Try Again") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
