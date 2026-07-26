import SwiftUI

/// The working captions vertical: drop a video, transcribe once, restyle
/// instantly. Layout follows the design mockup — content on the left,
/// caption settings in a fixed right panel.
struct CaptionsScreen: View {
    @Bindable var appState: AppState
    @Bindable var processor: VideoProcessorVM
    @Bindable var modelManager: ModelManagerVM
    var stylePreviews: StylePreviewsVM
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "Styled Captions", subtitle: subtitleLine) {
                HStack(spacing: 7) {
                    if case .done = processor.state {
                        if processor.subtitleURL != nil {
                            Button("Export .srt…") { processor.saveSubtitles() }
                                .controlSize(.small)
                        }
                        Button("Save Video…") { processor.saveVideo() }
                            .buttonStyle(AccentButtonStyle())
                    }
                    PanelToggleButton(
                        icon: "sidebar.right",
                        help: appState.captionSettingsCollapsed ? "Show settings" : "Hide settings"
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            appState.captionSettingsCollapsed.toggle()
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 20) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !appState.captionSettingsCollapsed {
                    settingsPanel
                        .frame(width: 300)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
    }

    private var subtitleLine: String {
        processor.videoURL?.lastPathComponent
            ?? "Burned-in animated subtitles, fully on-device"
    }

    @ViewBuilder
    private var content: some View {
        switch processor.state {
        case .idle:
            CaptionsDropZone(appState: appState, processor: processor, modelManager: modelManager)

        case .processing(_, let percent, let message):
            ProcessingView(percent: percent, message: message,
                           processedSeconds: processor.processedMediaSeconds,
                           totalSeconds: processor.totalMediaSeconds)

        case .done:
            PreviewView(
                processor: processor,
                onReset: { processor.reset() }
            )

        case .error(let message):
            ErrorView(message: message, onRetry: { processor.reset() })
        }
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "Caption style")
                StylePickerView(processor: processor, previews: stylePreviews)
                checksCard
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
        }
        .cardSurface(theme)
    }

    /// Cue-level QA (reading speed, line length) is designed but the
    /// backend checks don't exist yet.
    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionLabel(text: "Checks")
                Spacer()
                ComingSoonBadge()
            }
            Text("Piko will flag cues that read faster than 20 characters per second "
                 + "and split lines longer than 42 characters.")
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Drop Zone

struct CaptionsDropZone: View {
    @Bindable var appState: AppState
    @Bindable var processor: VideoProcessorVM
    @Bindable var modelManager: ModelManagerVM
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if let videoURL = processor.videoURL {
                selectedVideo(videoURL)
            } else {
                emptyDropZone
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(theme)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
        .onDrop(of: [.movie, .fileURL], isTargeted: nil) { providers in
            processor.handleDrop(providers: providers)
        }
    }

    /// Visible only while a video can't start on its own — i.e. the model
    /// isn't downloaded yet. Otherwise processing kicks off automatically
    /// the moment a video arrives.
    private func selectedVideo(_ videoURL: URL) -> some View {
        VStack(spacing: 16) {
            VideoThumbView(path: videoURL.path, cornerRadius: 10)
                .frame(width: 200, height: 120)

            Text(videoURL.lastPathComponent)
                .font(.title3.bold())
                .foregroundStyle(theme.text)

            if modelManager.isSelectedModelDownloaded {
                ProgressView()
                    .controlSize(.small)
                Text("Starting…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.dim)
            } else {
                VStack(spacing: 6) {
                    Text("Waiting for the Whisper model — it isn't downloaded yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dim)
                    Text("Processing starts automatically once it's ready.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.dim)
                    Button("Open Models") { appState.screen = .models }
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }

            Button("Choose Different Video") {
                processor.selectFile()
            }
            .controlSize(.small)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 48))
                .foregroundStyle(theme.dim)

            Text("Drop Video Here")
                .font(.title2.bold())
                .foregroundStyle(theme.text)

            Text("or click to browse")
                .foregroundStyle(theme.dim)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            processor.selectFile()
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
