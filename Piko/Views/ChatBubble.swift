import SwiftUI

// MARK: - One bubble

struct ChatBubble: View {
    let turn: ChatTurn
    @Environment(\.pikoTheme) private var theme
    @Environment(\.seekToTime) private var seek

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            bubble
            // Under the box and outside it, the way LM Studio does it: what the
            // run cost is about the answer, not part of it. Inside the bubble it
            // would read as something the model said.
            if let stats = turn.stats, !turn.isStreaming { statsLine(stats) }
        }
    }

    private var bubble: some View {
        HStack(alignment: .top, spacing: 10) {
            if turn.role == .user { Spacer(minLength: 40) }

            if let attachment = turn.attachment {
                fileChip(attachment)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    if turn.role == .assistant, let source = turn.source {
                        sourceBadge(source)
                    }
                    if let pasted = turn.pasted { pastedChip(pasted) }
                    if turn.isThinking { thinkingRow }
                    Text(rendered)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        // A timecode the model quoted is the same citation the
                        // transcript rows carry, so it goes to the same place.
                        .environment(\.openURL, OpenURLAction { url in
                            guard let seconds = Self.seconds(fromSeek: url) else {
                                return .systemAction
                            }
                            seek?(seconds)
                            return .handled
                        })
                }
                .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(turn.role == .user ? theme.accent.opacity(0.14) : theme.card2)
                }
            }

            if turn.role == .assistant { Spacer(minLength: 40) }
        }
    }

    /// The model is reasoning and nothing is coming out yet.
    ///
    /// The thinking itself is never shown — it is the model talking to itself,
    /// and a draft presented as an answer is worse than a wait. But an empty
    /// bubble for eight seconds is indistinguishable from a hang, so the wait
    /// says what it is.
    private var thinkingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            Text("thinking…")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
        }
    }

    /// What the run cost, in the order the run spends it: reading the prompt,
    /// waiting for the first token, writing the answer, and the whole thing.
    ///
    /// The two rates are the model's own and the two times are wall-clock, so a
    /// cold load shows up in `total` while `gen` stays fast — which is exactly
    /// the case worth being able to see, because the two feel identical from the
    /// outside and have completely different fixes.
    private func statsLine(_ stats: ChatStats) -> some View {
        var parts: [String] = []
        if let tokens = stats.promptTokens, tokens > 0 {
            var prompt = "\(tokens) tok in"
            if let tps = stats.promptTps { prompt += String(format: " · %.0f tok/s", tps) }
            parts.append(prompt)
        }
        if let ttft = stats.ttftSeconds {
            parts.append(String(format: "%.2fs to first token", ttft))
        }
        if let tokens = stats.generationTokens, tokens > 0 {
            var generated = "\(tokens) tok out"
            if let tps = stats.generationTps { generated += String(format: " · %.1f tok/s", tps) }
            parts.append(generated)
        }
        if let total = stats.totalSeconds {
            parts.append(String(format: "%.2fs total", total))
        }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(theme.dim)
            .textSelection(.enabled)
            .padding(.leading, 2)
    }

    /// Says where the answer came from. Cheap to render, and the whole reason
    /// a written first answer is defensible rather than a trick.
    private func sourceBadge(_ source: ChatTurn.Source) -> some View {
        Text(source == .written ? "written answer · no model needed" : "local model")
            .font(.system(size: 10))
            .foregroundStyle(theme.dim)
    }

    /// Material that came in with the question. The model gets all of it; the
    /// thread gets a line saying how much, because four hundred lines inside a
    /// bubble is how a conversation stops being readable.
    private func pastedChip(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 9.5))
            Text("Pasted text · \(text.count) characters")
                .font(.system(size: 10.5))
        }
        .foregroundStyle(theme.dim)
        .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 9))
        .background { Capsule().fill(theme.card) }
    }

    /// A handed-over file reads as a thing, not a sentence about a thing.
    private func fileChip(_ name: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 13))
        .background {
            Capsule().fill(theme.card2)
                .overlay { Capsule().strokeBorder(theme.line) }
        }
    }

    /// Markdown is parsed so the written answer's emphasis reads as emphasis;
    /// a model's stray asterisks fall back to plain text rather than erroring.
    private var rendered: AttributedString {
        let text = turn.text + (turn.isStreaming ? "▍" : "")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var string = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        if seek != nil { Self.linkTimecodes(in: &string) }
        return string
    }

    // MARK: - Timecodes the model wrote

    /// `04:12` and `1:04:12` in an answer, turned into somewhere to click.
    ///
    /// The model is given the transcript with timecodes on it and quotes them
    /// back — which makes the answer checkable in principle and useless in
    /// practice if the reader has to find that minute by hand. Linkifying is
    /// deliberately done on the *rendered* string rather than asking the model
    /// for markdown links: a small local model gets link syntax wrong often
    /// enough that the answer would arrive with broken brackets in it.
    private static let timecodePattern = try? NSRegularExpression(
        pattern: "\\b(?:([0-9]{1,2}):)?([0-5]?[0-9]):([0-5][0-9])\\b")

    private static func linkTimecodes(in string: inout AttributedString) {
        guard let pattern = timecodePattern else { return }
        let plain = String(string.characters)
        let full = NSRange(plain.startIndex..., in: plain)
        // Backwards so an earlier edit cannot shift a later match's offsets.
        for match in pattern.matches(in: plain, range: full).reversed() {
            func piece(_ index: Int) -> Int? {
                guard let range = Range(match.range(at: index), in: plain) else { return nil }
                return Int(plain[range])
            }
            guard let minutes = piece(2), let secs = piece(3) else { continue }
            let total = (piece(1) ?? 0) * 3600 + minutes * 60 + secs
            guard let url = URL(string: "piko-seek://\(total)"),
                  let plainRange = Range(match.range, in: plain),
                  let range = Range(plainRange, in: string)
            else { continue }
            string[range].link = url
            string[range].underlineStyle = .single
        }
    }

    private static func seconds(fromSeek url: URL) -> Double? {
        guard url.scheme == "piko-seek" else { return nil }
        let digits = (url.host() ?? url.absoluteString.replacingOccurrences(
            of: "piko-seek://", with: ""))
        return Double(digits)
    }
}
