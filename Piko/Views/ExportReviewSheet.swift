import AppKit
import EventKit
import SwiftUI

/// The one confirm step in the whole feature.
///
/// Ticking, editing and deleting write straight through — but this writes into
/// the user's Reminders or Calendar, which is outward-facing and not trivially
/// undone. So the rows, their resolved dates and the backlink each entry will
/// carry are shown once before anything is created. One sheet, not a wizard.
///
/// The destination lives here rather than in two buttons on the card: most
/// action items are tasks, but the ones that *are* a meeting ("let's sync in
/// two weeks") belong in the calendar, and that is a per-send decision.
struct ExportReviewSheet: View {
    let items: [ComposedItem]
    let recording: MeetingRecording
    /// Holds the typed-in call link and guest list, so they survive the sheet.
    @Bindable var meeting: MeetingVM
    var initialTarget: TaskExporter.Target = .icsFile
    /// Called with the EventKit identifier per row id, so the caller can
    /// remember where each row went.
    let onExported: (TaskExporter.Target, [String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.pikoTheme) private var theme
    @State private var target: TaskExporter.Target = .icsFile
    @State private var picked: Set<String> = []
    @State private var isSending = false
    @State private var failure: String?
    /// A refused grant is the one failure with somewhere to go, so it gets a
    /// button rather than just a sentence.
    @State private var isDenied = false
    /// The meeting this recording came from, if the calendar knows it.
    @State private var context: MeetingContext?
    @State private var inheritsContext = true
    @State private var link = ""
    @State private var guests = ""
    @State private var organizer = ""

    /// What the entries actually get: the matched event, with anything typed in
    /// layered on top. Typed details win — the user knows better than a match.
    private var effectiveContext: MeetingContext? {
        let typed = SummaryEdits.FollowUp(
            conferenceURL: link.trimmingCharacters(in: .whitespaces).isEmpty ? nil : link,
            guests: guestList,
            organizer: organizer.contains("@") ? organizer : nil
        )
        let matched = inheritsContext ? context : nil
        guard let matched else { return MeetingContext.manual(for: recording, followUp: typed) }
        return typed.isEmpty ? matched : matched.overridden(by: typed)
    }

    private var guestList: [String] {
        guests.split(whereSeparator: { ",; ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
    }

    private let exporter = TaskExporter()

    /// A calendar entry needs a day; a reminder does not. Rows that cannot go
    /// stay visible but unselectable — "why is this one missing" is a worse
    /// question than "why is this one greyed out".
    private func isEligible(_ item: ComposedItem) -> Bool {
        !target.requiresDate || item.dueDate != nil
    }

    private var selected: [ComposedItem] {
        items.filter { picked.contains($0.id) && isEligible($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            targetPicker
            if target.requiresDate {
                if let context { contextRow(context) }
                followUpFields
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .frame(maxHeight: 300)

            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if isDenied, let url = target.settingsURL {
                        Button("Open Settings") { NSWorkspace.shared.open(url) }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            }

            HStack(spacing: 10) {
                Text("\(selected.count) selected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dim)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(isSending)
                // The corporate case: no compose URL exists, and the invitation
                // has to go out by mail like every other invitation does.
                if target == .icsFile, !guestList.isEmpty {
                    Button("Email invite…") { emailInvite() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(selected.isEmpty || isSending)
                }
                Button(isSending ? "Creating…" : "Create") { send() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(selected.isEmpty || isSending)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        .frame(width: 620)
        .background(theme.pane)
        .onAppear {
            target = initialTarget
            reselect()
            link = meeting.edits.followUp?.conferenceURL ?? ""
            guests = (meeting.edits.followUp?.guests ?? []).joined(separator: ", ")
            organizer = meeting.edits.followUp?.organizer ?? ""
        }
        .task { await lookUpContext() }
        .onChange(of: target) { _, _ in
            reselect()
            Task { await lookUpContext() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Send to \(target.title)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(target.explanation)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What was matched, and the switch to refuse it. Shown rather than applied
    /// quietly: an inherited call link is a claim about which meeting this was,
    /// and a wrong one would send everybody to the wrong room.
    private var targetPicker: some View {
        HStack(spacing: 2) {
            ForEach(TaskExporter.Target.allCases) { option in
                Button {
                    target = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: target == option ? .medium : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(target == option ? theme.accent : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(target == option ? theme.accentOn : theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.card2, in: RoundedRectangle(cornerRadius: 8))
        .frame(width: 260)
    }

    private func contextRow(_ context: MeetingContext) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.summaryLine)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                Text(inheritsContext
                     ? "The follow-up gets its time of day, its call link and a note of who was on it."
                     : "Ignored — the follow-up will be a plain all-day entry.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dim)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $inheritsContext)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Typing in what the calendar could not supply. Both fields are optional
    /// and both are remembered with the meeting: an imported recording has no
    /// event to inherit from, and plenty of calls are in nobody's calendar.
    ///
    /// Guests only become a real invitation on the ICS path — EventKit refuses
    /// to write attendees, by design. On the Calendar path they are listed in
    /// the note so you know who to add.
    private var followUpFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("Call link", placeholder: "https://meet.google.com/…", text: $link)
            field("Guests", placeholder: "anna@team.com, dima@team.com", text: $guests)
            GuestGroupsRow(guests: $guests, guestList: guestList)
            // Without a sender an .ics with guests is not a valid invitation,
            // and clients fill the organizer in with whatever they please.
            if !guestList.isEmpty {
                field("From", placeholder: "you@team.com", text: $organizer)
            }
            if !guestList.isEmpty, target == .calendar {
                Text("EventKit cannot add guests to an event — they go into the note instead. "
                     + "Use ICS to send a real invitation.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.dim)
            }
        }
    }

    private func field(_ label: String, placeholder: String,
                       text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .frame(width: 62, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1)
                )
        }
    }

    private func row(_ item: ComposedItem) -> some View {
        let eligible = isEligible(item)
        let isOn = picked.contains(item.id) && eligible
        return Button {
            if isOn { picked.remove(item.id) } else { picked.insert(item.id) }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(isOn ? theme.accent : .clear)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isOn ? .clear : theme.dim, lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.accentOn)
                    }
                }
                .frame(width: 15, height: 15)

                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)

                if let label = DueDate.label(item.dueDate, time: item.dueTime) {
                    Text(label)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(theme.text)
                } else {
                    Text(target.requiresDate ? "needs a date" : "no due date")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                }

                Text(PikoURL.shortLabel(at: item.start))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.dim)
                if item.export(to: target.rawValue) != nil {
                    Text("update")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.positive)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isOn ? theme.card2 : theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn ? theme.accent : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(eligible ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!eligible)
    }

    /// Reading the calendar needs the same grant writing to it does, so picking
    /// Calendar is what raises the prompt — not pressing Create. That way the
    /// inherited meeting is on screen *before* anything is written.
    private func lookUpContext() async {
        guard target.requiresDate, context == nil else { return }
        // The file path needs no permission of its own, so it must not raise a
        // prompt — it only reuses a grant that already exists.
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            guard target.needsPermission else { return }
            try? await exporter.requestAccess(.calendar)
        }
        context = exporter.context(for: recording)
    }

    /// Everything eligible and still open, pre-picked: the common case is
    /// sending the whole list right after reading the summary.
    private func reselect() {
        picked = Set(items.filter { !$0.isDone && isEligible($0) }.map(\.id))
    }

    private func send() {
        isSending = true
        failure = nil
        isDenied = false
        let destination = target
        let inherited = effectiveContext
        meeting.setFollowUp(link: link, guests: guestList, organizer: organizer)

        if destination == .icsFile {
            saveFile(context: inherited)
            return
        }

        Task {
            do {
                let identifiers = try await exporter.send(selected, from: recording,
                                                          to: destination, context: inherited)
                onExported(destination, identifiers)
                dismiss()
            } catch {
                if case TaskExporter.ExportError.denied = error { isDenied = true }
                failure = error.localizedDescription
            }
            isSending = false
        }
    }

    /// Straight into a mail draft: guests in the To: field, the .ics attached.
    /// Nothing is sent by Piko — the draft opens and the user presses send.
    private func emailInvite() {
        guard let document = CalendarFile.make(selected, from: recording,
                                               context: effectiveContext) else {
            failure = TaskExporter.ExportError.needsDate.localizedDescription
            return
        }
        meeting.setFollowUp(link: link, guests: guestList, organizer: organizer)
        guard CalendarFile.email(document, to: guestList, subject: selected.first?.text ?? recording.title) else {
            failure = "No mail app is set up on this Mac to send the invitation with."
            return
        }
        dismiss()
    }

    /// The file path: no store, no permission, and the calendar app takes over
    /// once it opens. The row remembers the path it was written to, which is
    /// all a snapshot can honestly claim.
    private func saveFile(context: MeetingContext?) {
        defer { isSending = false }
        guard let document = CalendarFile.make(selected, from: recording, context: context) else {
            failure = TaskExporter.ExportError.needsDate.localizedDescription
            return
        }
        guard let url = CalendarFile.save(document, suggestedName: recording.title) else {
            return  // cancelled in the save panel
        }
        onExported(.icsFile, Dictionary(uniqueKeysWithValues: selected.map { ($0.id, url.path) }))
        dismiss()
    }
}
