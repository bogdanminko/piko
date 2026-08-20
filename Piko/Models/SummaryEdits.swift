import Foundation

/// Everything a person did to a generated summary, kept apart from the summary
/// itself.
///
/// `summary.json` stays strictly derived — the backend may rewrite it on any
/// rerun. This overlay (`summary.edits.json`) is the user's side of the same
/// meeting: corrections, ticked boxes, items they added or removed, and where
/// an item was exported to. The screen renders the composition of the two
/// (`ComposedSummary.make`), so a rerun can never destroy an edit.
struct SummaryEdits: Codable, Equatable {
    var version: Int = 1
    /// Whole-field overrides. Nil means "whatever the model wrote".
    var brief: String?
    var summary: String?
    var topics: [String]?
    var items: [ItemEdit] = []
    /// Who and where a follow-up should point at, when the calendar cannot say.
    var followUp: FollowUp?
    /// What every action item from this meeting starts out with.
    var defaults: Defaults?

    var isEmpty: Bool {
        brief == nil && summary == nil && topics == nil && items.isEmpty
            && (followUp?.isEmpty ?? true) && (defaults?.isEmpty ?? true)
    }

    /// Answers that belong to the call rather than to one row.
    ///
    /// An epic is the clearest case: the tasks from one planning call almost
    /// always land under the same one, and nothing in the transcript can say
    /// which — nobody reads a Jira key out loud. So it is stated once here and
    /// inherited by every row, which may still override it.
    struct Defaults: Codable, Equatable {
        /// Jira's epic key, or whatever the tracker calls its parent.
        var epic: String?

        var isEmpty: Bool { epic?.isEmpty ?? true }
    }

    /// The call link and the guest list for follow-ups from this meeting.
    ///
    /// Normally inherited from the calendar event the recording was matched to
    /// — but an imported file has no such event, and plenty of calls are not in
    /// anyone's calendar. Typed once, it is remembered with the meeting.
    struct FollowUp: Codable, Equatable {
        var conferenceURL: String?
        /// Email addresses; an `.ics` turns them into real ATTENDEE lines.
        var guests: [String] = []
        /// The user's own address. An invitation with guests but no organizer
        /// is not a well-formed REQUEST, and clients then invent one.
        var organizer: String?

        var isEmpty: Bool {
            (conferenceURL?.isEmpty ?? true) && guests.isEmpty && (organizer?.isEmpty ?? true)
        }
    }

    /// Which of the three lists an item belongs to. An edit may move an item
    /// between them: small models routinely file a proposal as a decision, and
    /// fixing that must not require running the model again.
    enum List: String, Codable, CaseIterable {
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    enum Origin: String, Codable {
        /// Came from the model, and still matches an item it produced.
        case generated
        /// Typed by the user.
        case manual
        /// Came from the model, but the latest rerun no longer produces it.
        /// Kept visible rather than deleted — losing text a person wrote or
        /// ticked is not recoverable, showing one stale row is.
        case orphaned
    }

    /// Where a generated item was, so the edit can find it again after a rerun
    /// shifts the citation by a few seconds and rewords the text.
    struct Anchor: Codable, Equatable {
        var list: List
        var start: Double
        /// Normalized text — see `SummaryEdits.fingerprint`.
        var fingerprint: String
    }

    struct ExportRecord: Codable, Equatable {
        /// "reminders" today; "calendar" once time-blocking lands.
        var target: String
        /// Identifier in the destination app, so a re-export updates instead of
        /// creating a second copy.
        var externalID: String
        var exportedAt: Date
    }

    struct ItemEdit: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        var anchor: Anchor?
        var list: List
        var origin: Origin = .generated

        var text: String?
        // The overridable fields below share one convention, and it is the
        // reason they are `String?` rather than `String`: nil is "the model's
        // answer stands", and an *empty* string is "the user cleared it". Two
        // different things — without the second there is no way to delete an
        // owner the model invented, and Restore would have nothing to restore.
        // See `SummaryEdits.override`.
        var owner: String?
        var due: String?
        var dueDate: String?
        var dueTime: String?
        /// Never generated: no transcript states a Jira key. Inherited from the
        /// meeting's defaults when this is nil, cleared when it is empty.
        var epic: String?
        /// Manual items only — generated ones take the start from their anchor.
        var start: Double?

        var deleted: Bool = false
        var done: Bool = false
        var doneAt: Date?
        var exports: [ExportRecord] = []

        /// True when the user changed what the item *says*, as opposed to only
        /// ticking or exporting it. Drives the "edited" marker.
        var changesContent: Bool {
            text != nil || owner != nil || due != nil || dueDate != nil || dueTime != nil
                || epic != nil
        }

        /// Nothing left worth keeping on disk — the row is back to what the
        /// model produced, so the edit can go away entirely.
        var isNoop: Bool {
            origin == .generated && !deleted && !done && exports.isEmpty && !changesContent
        }
    }

    /// Which of an override and a generated value the screen should show.
    ///
    /// nil override → whatever was generated. Empty override → nothing, because
    /// the user deleted it on purpose. Anything else → what they typed.
    static func override(_ edit: String?, _ generated: String?) -> String? {
        guard let edit else { return generated }
        return edit.isEmpty ? nil : edit
    }

    /// Text reduced to what survives rewording: lowercase word characters.
    static func fingerprint(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func anchor(for item: MeetingSummary.Item, in list: List) -> Anchor {
        Anchor(list: list, start: item.start, fingerprint: fingerprint(item.text))
    }
}
