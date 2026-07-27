import SwiftUI

/// One person's ids, edited where the name was just typed.
///
/// There is no People screen and there is deliberately no Contacts grant: the
/// only question this answers is "who is Anna in Jira", it comes up exactly when
/// somebody is being made responsible for something, and it is answered once per
/// person for as long as they work here. A settings pane for that would be a
/// screen visited twice a year to hold four text fields.
///
/// What is stored is a translation, not a directory: the spoken name on one side
/// and the id each tracker insists on on the other. See People.swift for why the
/// name alone cannot do the job.
struct PersonEditor: View {
    /// The name as it was typed into the assignee field — the key everything
    /// here hangs off, and the name a new entry is created under.
    let name: String
    /// The saved person this name already resolves to, if any.
    let person: Person?
    /// Fired with the whole book after every change, so the caller redraws.
    let onChange: ([Person]) -> Void

    @Environment(\.pikoTheme) private var theme
    @State private var email = ""
    @State private var handles: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            field("Email", placeholder: "anna@team.com", text: Binding(
                get: { email },
                set: { email = $0; save() }
            ))
            ForEach(LinkPreset.assigneeServices) { preset in
                field(preset.name, placeholder: hint(for: preset), text: Binding(
                    get: { handles[preset.service] ?? "" },
                    set: { handles[preset.service] = $0; save() }
                ))
            }
            Text("Used for the assignee field when a row is opened in that tracker. "
                 + "Anything left empty is simply not sent — an id Piko had to guess "
                 + "would assign the task to nobody.")
                .font(.system(size: 10))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .onAppear {
            email = person?.email ?? ""
            handles = person?.handles ?? [:]
        }
    }

    /// Where to find the id, per tracker. Jira Cloud hides the accountId in the
    /// URL of a person's profile and nowhere else, which is worth saying once.
    private func hint(for preset: LinkPreset) -> String {
        switch preset.service {
        case "jira": return "accountId — in the URL of their Jira profile"
        case "github": return "username, without the @"
        default: return "id in \(preset.name)"
        }
    }

    private func field(_ label: String, placeholder: String,
                       text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)
                .frame(width: 74, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line, lineWidth: 1))
        }
    }

    /// Written as you type, like every other edit in this feature. A new person
    /// is created under the typed name; an existing one keeps their id, so
    /// filling in a second tracker does not fork them into two entries.
    private func save() {
        guard let typed = name.nonEmpty else { return }
        let ids = handles.compactMapValues(\.nonEmpty)
        // Opening the fields and typing nothing must not leave an entry behind:
        // a person with a name and no ids is exactly what the book is for not
        // having.
        guard person != nil || email.nonEmpty != nil || !ids.isEmpty else { return }
        var updated = person ?? Person(name: typed)
        updated.email = email.nonEmpty
        updated.handles = ids
        // The name that was said is what the summary will keep saying, so it
        // joins the aliases rather than replacing what the entry is called.
        if !updated.matches(typed) {
            updated.aliases.append(typed)
        }
        onChange(PeopleBook.update(updated))
    }
}
