import SwiftUI

/// Editing one guest group, in a popover off its chip.
///
/// There is no People screen, on purpose: a group is remembered where it is
/// used, and this is the moment you think about it — you are inviting someone.
/// A section in the sidebar would hold two lists and a lot of empty space.
struct GuestGroupEditor: View {
    let group: GuestGroup
    /// Called with the new list after any change, so the row can redraw.
    let onChange: ([GuestGroup]) -> Void
    let onClose: () -> Void

    @Environment(\.pikoTheme) private var theme
    @State private var name: String
    @State private var emails: [String]
    @State private var newEmail = ""

    init(group: GuestGroup,
         onChange: @escaping ([GuestGroup]) -> Void,
         onClose: @escaping () -> Void) {
        self.group = group
        self.onChange = onChange
        self.onClose = onClose
        _name = State(initialValue: group.name)
        _emails = State(initialValue: group.emails)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Group name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text)
                .onSubmit(commit)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(emails, id: \.self) { email in
                    HStack(spacing: 8) {
                        Text(email)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 6)
                        Button {
                            emails.removeAll { $0 == email }
                            commit()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(theme.dim)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from the group")
                    }
                }
            }

            TextField("add@person.com", text: $newEmail)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line, lineWidth: 1))
                .onSubmit(addTyped)

            HStack(spacing: 8) {
                Button("Delete group", role: .destructive) {
                    onChange(GuestGroupStore.remove(group))
                    onClose()
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Done") {
                    addTyped()
                    commit()
                    onClose()
                }
                .buttonStyle(AccentButtonStyle(compact: true))
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func addTyped() {
        let candidate = newEmail.trimmingCharacters(in: .whitespaces)
        guard candidate.contains("@"), !emails.contains(candidate) else { return }
        emails.append(candidate)
        newEmail = ""
        commit()
    }

    /// Saved as you go — the popover has no Cancel, so there is nothing to
    /// discard and nothing to forget to press.
    private func commit() {
        onChange(GuestGroupStore.update(
            GuestGroup(id: group.id, name: name, emails: emails)
        ))
    }
}
