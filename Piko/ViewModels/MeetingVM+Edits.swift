import Foundation

/// Editing a summary: everything a person does to the model's output.
///
/// Split out of MeetingVM because it is one closed idea — the overlay in
/// `summary.edits.json` — and because the view model was long enough without
/// it. See SummaryEdits.swift for why edits live beside the summary instead of
/// inside it.
@MainActor
extension MeetingVM {
    //
    // Every mutation goes through `mutate`: find the edit backing this row or
    // mint one, change it, drop it if it no longer says anything, save. There
    // is no save button — an edit is written the moment it is made.

    func toggleDone(_ item: ComposedItem) {
        mutate(item) { edit in
            edit.done.toggle()
            edit.doneAt = edit.done ? Date() : nil
        }
    }

    func setText(_ text: String, for item: ComposedItem) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.text else { return }
        mutate(item) { edit in
            // Back to the model's wording: drop the override instead of
            // storing a copy of it, so the row stops reading as edited.
            edit.text = trimmed == item.generated?.text ? nil : trimmed
        }
    }

    func setOwner(_ owner: String?, for item: ComposedItem) {
        let trimmed = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(item) { edit in
            edit.owner = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// Removes the row. A generated item is remembered as deleted — otherwise
    /// the next composition would simply show it again.
    func delete(_ item: ComposedItem) {
        // A manual item has no anchor, so a tombstone would never match
        // anything — it just goes. Anything anchored keeps one, or the next
        // composition would show it again.
        if item.anchor == nil, let editID = item.editID {
            edits.items.removeAll { $0.id == editID }
            persistEdits()
            return
        }
        mutate(item) { $0.deleted = true }
    }

    /// Back to what the model wrote. Ticks and export records survive: the
    /// button restores the *text*, and un-ticking is not what it promises.
    func restoreGenerated(_ item: ComposedItem) {
        guard item.generated != nil else { return }
        mutate(item) { edit in
            edit.text = nil
            edit.owner = nil
            edit.due = nil
            edit.dueDate = nil
            edit.dueTime = nil
            edit.deleted = false
        }
    }

    /// A task nobody stated but everybody left with. It has no citation, which
    /// is exactly why it is marked "manual" rather than dressed up as one.
    func addManualItem(to list: SummaryEdits.List = .actionItems,
                       text: String = "",
                       start: Double? = nil) {
        edits.items.append(
            SummaryEdits.ItemEdit(anchor: nil, list: list, origin: .manual,
                                  text: text, start: start)
        )
        persistEdits()
    }

    /// Remembers where a row went, so a second send updates that reminder
    /// instead of creating a duplicate.
    func recordExport(_ externalID: String, target: String, for item: ComposedItem) {
        mutate(item) { edit in
            edit.exports.removeAll { $0.target == target }
            edit.exports.append(
                SummaryEdits.ExportRecord(target: target, externalID: externalID,
                                          exportedAt: Date())
            )
        }
    }

    func clearExport(target: String, for item: ComposedItem) {
        mutate(item) { $0.exports.removeAll { $0.target == target } }
    }

    /// Items removed from this list and still remembered as removed. A
    /// generated item leaves a tombstone rather than vanishing, which is what
    /// makes one click on the bin recoverable.
    func removedCount(in list: SummaryEdits.List = .actionItems) -> Int {
        edits.items.filter { $0.deleted && $0.list == list }.count
    }

    func restoreRemoved(in list: SummaryEdits.List = .actionItems) {
        for index in edits.items.indices where edits.items[index].deleted
            && edits.items[index].list == list {
            edits.items[index].deleted = false
        }
        edits.items.removeAll { $0.isNoop }
        persistEdits()
    }

    /// The call link and guest list to use for follow-ups from this meeting.
    /// Typed once and remembered, because the second export should not ask for
    /// the same Meet link again.
    func setFollowUp(link: String?, guests: [String], organizer: String? = nil) {
        let trimmed = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = organizer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let followUp = SummaryEdits.FollowUp(
            conferenceURL: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            guests: guests,
            organizer: (sender?.contains("@") ?? false) ? sender : nil
        )
        edits.followUp = followUp.isEmpty ? nil : followUp
        persistEdits()
    }

    /// What a follow-up should inherit when the calendar has nothing to offer.
    func manualContext(for recording: MeetingRecording) -> MeetingContext? {
        guard let followUp = edits.followUp else { return nil }
        return MeetingContext.manual(for: recording, followUp: followUp)
    }

    private func mutate(_ item: ComposedItem, _ apply: (inout SummaryEdits.ItemEdit) -> Void) {
        var edit: SummaryEdits.ItemEdit
        var index: Int?
        if let editID = item.editID, let found = edits.items.firstIndex(where: { $0.id == editID }) {
            edit = edits.items[found]
            index = found
        } else {
            edit = SummaryEdits.ItemEdit(anchor: item.anchor, list: item.list,
                                         origin: item.origin, start: item.start)
        }

        apply(&edit)

        if let index {
            if edit.isNoop {
                edits.items.remove(at: index)
            } else {
                edits.items[index] = edit
            }
        } else if !edit.isNoop {
            edits.items.append(edit)
        }
        persistEdits()
    }

    private func persistEdits() {
        guard let selectedID else { return }
        try? MeetingLibrary.saveEdits(edits, for: selectedID)
    }
}
