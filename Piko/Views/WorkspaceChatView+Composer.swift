import AppKit
import SwiftUI

/// The composer.
///
/// Two rows inside one continuously-curved surface, rather than a single line
/// of controls with a field wedged between them. The field gets the top row to
/// itself so a four-line question does not squeeze the buttons sideways, and
/// the buttons get a row where their meaning is readable instead of being
/// inferred from a 20 pt glyph.
///
/// The curve is `.continuous`, not `.circular`: at this radius a circular
/// corner meets the straight edge with a visible break in curvature, and the
/// eye reads that as a slightly wrong shape without being able to say why.
extension WorkspaceChatView {
    /// Big enough to look like the thing you type into rather than a strip at
    /// the bottom of the window.
    static let composerRadius: CGFloat = 22

    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pasted = chat.pasted { pasteChip(pasted) }
            TextField(placeholder, text: Bindable(chat).draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text)
                .lineLimit(2...8)
                .focused($composerFocused)
                // Never disabled. A box that stops accepting keystrokes while
                // the answer you are reading goes the wrong way is a box that
                // is shut exactly when you have something to say.
                .onSubmit(submit)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 8) {
                composerButton(icon: showsSlashPanel ? "xmark" : "plus",
                               help: "Shortcuts") { showsSlashPanel.toggle() }
                composerButton(icon: "paperclip",
                               help: "Add a recording or a video", action: onAttach)

                // What can actually be handed over, said where the handing
                // over happens rather than in a help page nobody opens.
                Text("mp4 · mov · m4a · wav · mp3")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
                    .padding(.leading, 2)

                Spacer(minLength: 8)

                // Stop only while there is nothing to say. The moment there
                // is, the same key both stops the answer and sends — one
                // gesture, because "interrupt" and "here is the correction"
                // are one intention.
                if chat.isAnswering, !canSubmit {
                    stopButton
                } else {
                    sendButton
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
        .background {
            RoundedRectangle(cornerRadius: Self.composerRadius, style: .continuous)
                .fill(theme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: Self.composerRadius, style: .continuous)
                        .strokeBorder(composerFocused ? theme.accent.opacity(0.45) : theme.line)
                }
        }
        // Typing should land here. Somebody who has just read an answer and
        // starts typing is talking to the chat, and making them find the box
        // with a mouse first is a tax on the only thing this screen asks of
        // them. Re-taken when the composer unlocks and after every send.
        .onAppear {
            takeFocus()
            watchForLargePastes()
        }
        .onDisappear {
            if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
        }
        .onChange(of: chat.isAnswering) { _, isAnswering in
            if !isAnswering { takeFocus() }
        }
        .onChange(of: composerFocused) { _, focused in
            chat.isComposerFocused = focused
        }
    }

    /// A paste too big to type, held where it can be seen and dropped.
    private func pasteChip(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.accent)
            Text("Pasted text · \(text.count) characters")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text)
            Button { chat.dropPaste() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.dim)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the pasted text")
        }
        .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 6))
        .background {
            Capsule().fill(theme.card2)
                .overlay { Capsule().strokeBorder(theme.line) }
        }
        .padding(.horizontal, 6)
    }

    /// Catch ⌘V before the field sees it.
    ///
    /// After the fact is too late: by the time the binding has been set, the
    /// text is in the field and the layout that hangs the app has already
    /// happened. So the event is intercepted and, when the clipboard holds more
    /// than a sentence, swallowed — the text becomes a chip instead.
    ///
    /// By key code, not by character: on a Russian layout the V key produces
    /// "м", so matching on the character misses every paste this is for.
    private func watchForLargePastes() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command), event.keyCode == 9,
                  chat.isComposerFocused,
                  let text = NSPasteboard.general.string(forType: .string),
                  text.count > WorkspaceChatVM.pasteThreshold
            else { return event }
            chat.attachPaste(text)
            return nil
        }
    }

    /// A tick late on purpose: focus set while the view is still being placed
    /// is dropped by AppKit without a word.
    ///
    /// And never out of a field that is already being typed in. Renaming a
    /// conversation in the sidebar and correcting a transcript line in the
    /// panel both happen beside this composer; pulling the caret back here a
    /// moment after they opened is what made those edits impossible to make.
    func takeFocus() {
        FieldFocus.take {
            guard !FieldFocus.isTyping else { return }
            composerFocused = true
        }
    }

    private func composerButton(icon: String,
                                help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.dim)
                .frame(width: 28, height: 28)
                .background { Circle().fill(theme.card2) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Round, and filled only when there is something to send — the one
    /// affordance on the row that has a state worth reading at a glance.
    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(canSubmit ? theme.accentOn : theme.dim)
                .background { Circle().fill(canSubmit ? theme.accent : theme.card2) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .help("Send")
    }

    private var stopButton: some View {
        Button { chat.cancel() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11))
                .frame(width: 30, height: 30)
                .foregroundStyle(theme.text)
                .background { Circle().fill(theme.card2) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop answering")
    }

    var placeholder: String { "Ask something, drop a file, or type / for shortcuts" }

    var canSubmit: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() {
        guard canSubmit else { return }
        let text = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = ChatCommand.all.first(where: { $0.name == text.lowercased() }) {
            chat.draft = ""
            showsSlashPanel = false
            onCommand(command)
            takeFocus()
            return
        }
        chat.send(text)
        takeFocus()
    }
}
