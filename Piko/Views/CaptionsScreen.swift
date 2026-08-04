import SwiftUI

/// A video artifact: transcribe once, correct the words, then style and burn
/// if a burned copy is what is wanted. Content on the left, caption settings
/// in a fixed right panel.
///
/// One of two readings the workspace can give a file, not a destination —
/// hence "Summarise as a Call" in the header, which is how a wrong guess gets
/// corrected without going back to a drop zone.
struct CaptionsScreen: View {
    @Bindable var appState: AppState
    @Bindable var processor: VideoProcessorVM
    @Bindable var modelManager: ModelManagerVM
    @Bindable var meeting: MeetingVM
    var stylePreviews: StylePreviewsVM
    /// Rendered as the expanded artifact panel rather than as a screen. The
    /// panel carries its own way back, and two chevrons one above the other
    /// that mean different things — collapse the panel, close the artifact —
    /// is worse than one.
    var embedded = false
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: title,
                         subtitle: subtitleLine,
                         onBack: embedded ? nil : { appState.show(.none) },
                         backBlockedReason: processor.isProcessing
                             ? "Cancel the run first"
                             : nil,
                         accessory: { headerActions })
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

    private var headerActions: some View {
        HStack(spacing: 7) {
            if case .done = processor.state {
                if processor.srtURL != nil {
                    Button("Save .srt…") { processor.saveSRT() }
                        .controlSize(.small)
                }
                Button("Save Video…") { processor.saveVideo() }
                    .buttonStyle(AccentButtonStyle())
            }
            reinterpretButton
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

    private var title: String {
        processor.videoURL?.deletingPathExtension().lastPathComponent ?? "Video"
    }

    private var subtitleLine: String {
        processor.videoURL == nil
            ? "Burned-in animated subtitles, fully on-device"
            : "Transcript, subtitle files, and a burned copy if you want one"
    }

    /// The other reading of the same file. The workspace guessed this was a
    /// clip to caption because it is short and has a picture; a screen-shared
    /// call under ten minutes is exactly where that guess is wrong, and the
    /// cost of being wrong should be one button, not a re-drop.
    @ViewBuilder
    private var reinterpretButton: some View {
        if let url = processor.videoURL {
            Button("Summarise as a Call") {
                appState.show(.meeting)
                Task {
                    // The words are already known — this file has just been
                    // transcribed. Handing that over is the difference between
                    // switching reading and paying for the whole ASR pass twice.
                    await meeting.importFile(at: url,
                                             model: modelManager.selectedModelId,
                                             diarize: modelManager.diarizationReady,
                                             reusing: processor.transcriptionPath)
                }
            }
            .controlSize(.small)
            .disabled(processor.isProcessing)
            .help(processor.transcriptionPath == nil
                  ? "Treat this recording as a conversation: summary, decisions, action items"
                  : "Reuses the transcript already made here — no second transcription")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch processor.state {
        case .idle:
            CaptionsDropZone(appState: appState, processor: processor, modelManager: modelManager)

        case .processing(_, let percent, let message):
            ProcessingView(percent: percent, message: message,
                           processedSeconds: processor.processedMediaSeconds,
                           totalSeconds: processor.totalMediaSeconds,
                           onCancel: { processor.cancel() })

        case .transcribed:
            TranscriptView(processor: processor, onBurn: { processor.burn() })

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

    /// What the caption layout actually guarantees. Written as statements
    /// rather than promises: everything listed here is enforced in
    /// `styles/base.py` and `plain.py`, and the card used to advertise rules
    /// that did not exist.
    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Layout rules")
            Text("Cards break at sentences and at pauses, never across a silence. "
                 + "Type size and margins scale with the frame, so vertical video "
                 + "clears the platform UI. Saved .srt lines wrap at 42 characters.")
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
