import SwiftUI

/// The three answers a summary cannot produce on its own: who owns this, when
/// it is actually due, and which epic it belongs under.
///
/// The model fills in an owner and a deadline whenever someone said them out
/// loud, and that is where its authority ends — nobody reads a Jira key into a
/// call, half of the tasks agreed on a call name no owner at all, and "by
/// Friday" is a phrase before it is a Friday. So this is not a correction
/// screen; it is the other half of the same field, and what is typed here wins
/// over what was generated without deleting it (see SummaryEdits.override).
///
/// One popover rather than three inline editors: they are answered together,
/// usually once per row, right before the row is sent somewhere.
struct ItemDetailsPopover: View {
    let item: ComposedItem
    /// The epic every row from this meeting starts under, shown as the
    /// placeholder so "leave it alone" is visibly the default.
    let defaultEpic: String?
    /// Names already used on this meeting, offered beside the saved people —
    /// the second task assigned to Anna should not need her name typed again.
    let suggestions: [String]
    let onSave: (_ owner: String?, _ date: String?, _ time: String?, _ epic: String?) -> Void
    let onClose: () -> Void

    @Environment(\.pikoTheme) private var theme
    @State private var owner: String
    @State private var epic: String
    @State private var hasDate: Bool
    @State private var day: Date
    @State private var hasTime: Bool
    @State private var clock: Date
    @State private var people: [Person] = []
    /// Open once somebody wants this name to reach a tracker's assignee field
    /// rather than only the description.
    @State private var isMappingPerson = false

    init(item: ComposedItem,
         defaultEpic: String?,
         suggestions: [String],
         onSave: @escaping (String?, String?, String?, String?) -> Void,
         onClose: @escaping () -> Void) {
        self.item = item
        self.defaultEpic = defaultEpic
        self.suggestions = suggestions
        self.onSave = onSave
        self.onClose = onClose
        _owner = State(initialValue: item.owner ?? "")
        _epic = State(initialValue: item.epic ?? "")
        let resolved = DueDate.date(from: item.dueDate, time: item.dueTime)
        _hasDate = State(initialValue: resolved != nil)
        _day = State(initialValue: resolved ?? Date())
        _hasTime = State(initialValue: item.dueTime != nil)
        _clock = State(initialValue: resolved ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            assigneeSection
            Rectangle().fill(theme.line).frame(height: 1)
            dueSection
            Rectangle().fill(theme.line).frame(height: 1)
            epicSection
            HStack {
                Spacer()
                Button("Done") { commit() }
                    .buttonStyle(AccentButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { people = PeopleBook.load() }
    }

    // MARK: - Assignee

    private var matched: Person? { PeopleBook.find(owner, in: people) }

    private var assigneeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                label("Assignee")
                Spacer()
                if !candidates.isEmpty { peopleMenu }
            }
            TextField("Nobody yet", text: $owner)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1))
                .onSubmit { commit() }

            // The name alone reaches Markdown, the CSV and the description of
            // anything opened from here. Only an id reaches a real assignee
            // field, and saying so is the difference between a task that lands
            // on somebody and one that quietly lands on nobody.
            if let named = owner.nonEmpty {
                caption(assignability(named))
            }
            if owner.nonEmpty != nil {
                Button(isMappingPerson ? "Hide ids" : (matched == nil ? "Add ids…" : "Edit ids…")) {
                    isMappingPerson.toggle()
                }
                .buttonStyle(GhostButtonStyle())
            }
            if isMappingPerson {
                PersonEditor(name: owner, person: matched) { people = $0 }
            }
        }
    }

    /// What this name will actually do once the row leaves Piko. The name
    /// always travels; being *assigned* needs an id, and the difference between
    /// the two is the difference between a task somebody owns and one that
    /// quietly belongs to nobody.
    private func assignability(_ named: String) -> String {
        let trackers = matched?.assignableIn ?? []
        guard !trackers.isEmpty else {
            return "“\(named)” goes out as text — in the description, the Markdown and the CSV. "
                + "Assigning needs that person's id in the tracker."
        }
        return "Assigned in \(trackers.joined(separator: " and ")); a name everywhere else."
    }

    /// Everybody this meeting has already named, plus everybody the people file
    /// knows. Sorted and de-duplicated so one person cannot appear twice under
    /// two spellings of the same normalization.
    private var candidates: [String] {
        var seen = Set<String>()
        return (people.map(\.name) + suggestions)
            .compactMap(\.nonEmpty)
            .filter { seen.insert(PeopleBook.normalize($0)).inserted }
            .sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    private var peopleMenu: some View {
        Menu {
            ForEach(candidates, id: \.self) { name in
                Button(name) { owner = name }
            }
            if !owner.isEmpty {
                Divider()
                Button("Nobody") { owner = "" }
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Someone already named here, or in your people file")
    }

    // MARK: - Due

    private var dueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                label("Due")
                Spacer()
                if hasDate {
                    Button("Clear") { hasDate = false; hasTime = false }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            if hasDate {
                DatePicker("", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                HStack(spacing: 8) {
                    Toggle("At", isOn: $hasTime)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.dim)
                    if hasTime {
                        DatePicker("", selection: $clock, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                            .labelsHidden()
                    }
                }
            } else {
                Button("Pick a date") { hasDate = true; day = Date() }
                    .buttonStyle(GhostButtonStyle())
            }
            // The phrase stays visible while the date is being corrected: it is
            // the evidence the date was derived from, and it is the reason to
            // trust or distrust what the model resolved.
            if let spoken = item.due?.nonEmpty {
                caption("Said as “\(spoken)”.")
            }
            if hasDate, !hasTime {
                caption("No hour: a task is due that day, an event stays all-day.")
            }
        }
    }

    // MARK: - Epic

    private var epicSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Epic")
            TextField(defaultEpic ?? "PROJ-123", text: $epic)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line, lineWidth: 1))
                .onSubmit { commit() }
            if item.isEpicInherited, epic == defaultEpic {
                caption("From the meeting. Type another to change just this row, "
                        + "or clear it to leave this one out.")
            }
        }
    }

    // MARK: - Pieces

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(theme.dim)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// All three at once, on the way out. Each one is compared with what the
    /// row already showed inside the view model, so an untouched field never
    /// mints an override and the row does not start reading as edited for
    /// having been looked at.
    private func commit() {
        onSave(owner,
               hasDate ? DueDate.iso(day) : nil,
               hasDate && hasTime ? DueDate.clock(clock) : nil,
               epic)
        onClose()
    }
}
