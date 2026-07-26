import SwiftUI

/// Saved sets of people, one click each.
///
/// The same six addresses go into every follow-up with this team; typing them
/// again is work the app should have removed. A group is not tied to a meeting
/// — see GuestGroups.swift — so this row owns the list itself and hands back
/// only the guest field it edits.
struct GuestGroupsRow: View {
    /// The comma-separated guest field this row adds to.
    @Binding var guests: String
    /// Addresses already in that field, parsed by the sheet.
    let guestList: [String]

    @Environment(\.pikoTheme) private var theme
    @State private var groups: [GuestGroup] = []
    @State private var isNaming = false
    @State private var name = ""
    /// The group whose editor popover is open.
    @State private var editing: GuestGroup?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Groups")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .frame(width: 62, alignment: .leading)
            FlowLayout(spacing: 5) {
                ForEach(groups) { group in
                    chip(group)
                }
                if isNaming {
                    nameField
                } else if !guestList.isEmpty {
                    Button("+ Save as group") { isNaming = true }
                        .buttonStyle(GhostButtonStyle())
                }
            }
        }
        .onAppear { groups = GuestGroupStore.load() }
    }

    private func chip(_ group: GuestGroup) -> some View {
        Button { insert(group) } label: {
            HStack(spacing: 5) {
                Text(group.name)
                Text(group.subtitle)
                    .foregroundStyle(theme.dim)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(theme.card2, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(theme.text)
        }
        .buttonStyle(.plain)
        .help(group.emails.joined(separator: "\n"))
        .contextMenu {
            Button("Edit…") { editing = group }
            Button("Delete group", role: .destructive) {
                groups = GuestGroupStore.remove(group)
            }
        }
        // Anchored to the chip so the popover opens where the group is, not
        // over the middle of the sheet.
        .popover(isPresented: Binding(
            get: { editing?.id == group.id },
            set: { if !$0 { editing = nil } }
        )) {
            GuestGroupEditor(group: group,
                             onChange: { groups = $0 },
                             onClose: { editing = nil })
        }
    }

    private var nameField: some View {
        TextField("Group name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .frame(width: 120)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(theme.accent, lineWidth: 1)
            )
            .onSubmit {
                groups = GuestGroupStore.add(name: name, emails: guestList)
                name = ""
                isNaming = false
            }
    }

    /// Adds what is missing rather than replacing: two groups can be on the
    /// same call, and picking the second must not drop the first.
    private func insert(_ group: GuestGroup) {
        let existing = Set(guestList)
        let added = group.emails.filter { !existing.contains($0) }
        guard !added.isEmpty else { return }
        guests = (guestList + added).joined(separator: ", ")
    }
}
