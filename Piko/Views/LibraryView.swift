import SwiftUI

/// The full artifact library backend does not exist yet, but the table is
/// real: it lists the local processing history and reopens entries in
/// Captions. With no history yet it falls back to a dimmed design preview.
struct LibraryView: View {
    @Bindable var appState: AppState
    var processor: VideoProcessorVM
    var history: HistoryStore
    @Environment(\.pikoTheme) private var theme

    private struct SampleRow: Identifiable {
        let id = UUID()
        let title: String
        let kind: String
        let length: String
        let added: String
        let status: String
    }

    private let sampleRows = [
        SampleRow(title: "Team sync — July 12", kind: "Audio · M4A",
                  length: "58:12", added: "today, 11:02", status: "Summarized"),
        SampleRow(title: "Product demo for investors", kind: "Video · MOV",
                  length: "12:04", added: "yesterday, 19:40", status: "Captioned"),
        SampleRow(title: "Planning: Q3 roadmap", kind: "Audio · WAV",
                  length: "41:37", added: "July 24", status: "Transcribed"),
        SampleRow(title: "User interview #7", kind: "Audio · M4A",
                  length: "33:20", added: "July 23", status: "In queue"),
        SampleRow(title: "Incident review 07/04", kind: "Video · MP4",
                  length: "26:45", added: "July 21", status: "Summarized")
    ]

    private let columns: [GridItem] = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.fixed(120), alignment: .leading),
        GridItem(.fixed(70), alignment: .leading),
        GridItem(.fixed(120), alignment: .leading),
        GridItem(.fixed(100), alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "Library", subtitle: "One place for everything Piko has processed") {
                HStack(spacing: 10) {
                    ComingSoonBadge()
                    searchField
                }
            }
            dropCard
            tablePreview
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
    }

    private var searchField: some View {
        Text("Search artifacts")
            .font(.system(size: 12.5))
            .foregroundStyle(theme.dim)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(width: 200, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line))
    }

    private var dropCard: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 11)
                .fill(theme.card2)
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundStyle(theme.dim)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop anything.")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Video, audio, transcript or document — Piko will suggest matching skills.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
    }

    private var tablePreview: some View {
        let hasHistory = !history.entries.isEmpty
        return VStack(alignment: .leading, spacing: 7) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(["Artifact", "Kind", hasHistory ? "Words" : "Length", "Added", "Status"],
                        id: \.self) {
                    SectionLabel(text: $0)
                }
            }
            .padding(.horizontal, 12)

            if hasHistory {
                historyTable
            } else {
                sampleTable
            }

            Text(hasHistory
                 ? "Local processing history — the full artifact library ships with the Meeting Summary skill."
                 : "Sample data — the library ships together with the Meeting Summary skill.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .padding(.top, 4)
        }
    }

    private var historyTable: some View {
        VStack(spacing: 0) {
            ForEach(history.entries) { entry in
                Button {
                    openEntry(entry)
                } label: {
                    historyRow(entry)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.fileExists)
                if entry.id != history.entries.last?.id {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        LazyVGrid(columns: columns, spacing: 0) {
            HStack(spacing: 10) {
                VideoThumbView(path: entry.videoPath, cornerRadius: 5)
                    .frame(width: 38, height: 24)
                    .opacity(entry.fileExists ? 1 : 0.4)
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(entry.fileExists ? theme.text : theme.dim)
                    .lineLimit(1)
            }
            Text(entry.kind).font(.system(size: 12)).foregroundStyle(theme.dim)
            Text("\(entry.wordCount)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
            Text(entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .font(.system(size: 12))
                .foregroundStyle(theme.dim)
            Text("Captioned · \(entry.style)")
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(theme.positive)
                .lineLimit(1)
        }
        .padding(.vertical, 11)
    }

    /// Reopen a processed video on the Captions screen. Clicking the entry
    /// that is already open just navigates without restarting the pipeline.
    private func openEntry(_ entry: HistoryEntry) {
        appState.screen = .captions
        guard processor.videoURL?.path != entry.videoPath else { return }
        processor.reset()
        processor.videoURL = URL(fileURLWithPath: entry.videoPath)
    }

    private var sampleTable: some View {
        VStack(spacing: 0) {
            ForEach(sampleRows) { row in
                tableRow(row)
                if row.id != sampleRows.last?.id {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
        .opacity(0.55)
    }

    private func tableRow(_ row: SampleRow) -> some View {
        LazyVGrid(columns: columns, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.card2)
                    .frame(width: 22, height: 22)
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            }
            Text(row.kind).font(.system(size: 12)).foregroundStyle(theme.dim)
            Text(row.length).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
            Text(row.added).font(.system(size: 12)).foregroundStyle(theme.dim)
            Text(row.status)
                .font(.system(size: 11.5))
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(theme.positive)
        }
        .padding(.vertical, 11)
    }
}
