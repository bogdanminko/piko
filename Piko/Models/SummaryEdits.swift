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

    var isEmpty: Bool {
        brief == nil && summary == nil && topics == nil && items.isEmpty
            && (followUp?.isEmpty ?? true)
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
        var owner: String?
        var due: String?
        var dueDate: String?
        var dueTime: String?
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
        }

        /// Nothing left worth keeping on disk — the row is back to what the
        /// model produced, so the edit can go away entirely.
        var isNoop: Bool {
            origin == .generated && !deleted && !done && exports.isEmpty && !changesContent
        }
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

// MARK: - Composition

/// One row as the screen shows it: the model's item with the user's edit
/// applied, plus enough provenance to render "edited" and to restore.
struct ComposedItem: Identifiable, Equatable {
    var id: String
    var list: SummaryEdits.List
    var text: String
    var owner: String?
    /// The deadline as spoken. Kept beside the resolved date on purpose: it is
    /// the evidence, the date is the suggestion.
    var due: String?
    var dueDate: String?
    var dueTime: String?
    /// Position in the recording. Nil only for a manual item added without one.
    var start: Double?
    var isDone: Bool
    var isEdited: Bool
    var origin: SummaryEdits.Origin
    var exports: [SummaryEdits.ExportRecord]

    /// The edit backing this row, if one exists yet.
    var editID: UUID?
    /// Where to re-attach an edit minted from this row.
    var anchor: SummaryEdits.Anchor?
    /// What the model produced, for Restore.
    var generated: MeetingSummary.Item?

    var isExported: Bool { !exports.isEmpty }

    func export(to target: String) -> SummaryEdits.ExportRecord? {
        exports.first { $0.target == target }
    }
}

/// A whole summary as displayed: generated content plus the overlay.
struct ComposedSummary: Equatable {
    var brief: String
    var summary: String
    var topics: [String]
    var decisions: [ComposedItem]
    var actionItems: [ComposedItem]
    var openQuestions: [ComposedItem]
    var language: String?

    var isBriefEdited: Bool
    var isSummaryEdited: Bool
    var areTopicsEdited: Bool

    var isEmpty: Bool {
        brief.isEmpty && decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty
    }

    func items(in list: SummaryEdits.List) -> [ComposedItem] {
        switch list {
        case .decisions: return decisions
        case .actionItems: return actionItems
        case .openQuestions: return openQuestions
        }
    }

    /// How far a citation may move between reruns and still be the same item.
    /// A rerun cites a neighbouring transcript line, not a different minute.
    static let anchorTolerance: Double = 15
    /// Word overlap two texts need to count as the same item once the model has
    /// reworded it.
    static let anchorSimilarity: Double = 0.5

    static func make(_ summary: MeetingSummary, edits: SummaryEdits) -> ComposedSummary {
        var unused = edits.items
        var lists: [SummaryEdits.List: [ComposedItem]] = [:]

        // Generated items first, each claiming its edit if one still matches.
        for list in SummaryEdits.List.allCases {
            let generated = generatedItems(summary, list)
            var rows: [ComposedItem] = []
            for item in generated {
                let anchor = SummaryEdits.anchor(for: item, in: list)
                let matched = takeMatch(for: anchor, from: &unused)
                if let matched, matched.deleted { continue }
                rows.append(compose(item, anchor: anchor, edit: matched, list: list))
            }
            lists[list] = rows
        }

        // What is left: manual items, and edits whose generated item this rerun
        // no longer produces. Both stay visible.
        for edit in unused where !edit.deleted {
            var orphan = edit
            if orphan.origin == .generated { orphan.origin = .orphaned }
            let list = orphan.list
            lists[list, default: []].append(compose(nil, anchor: orphan.anchor, edit: orphan,
                                                    list: list))
        }

        for list in SummaryEdits.List.allCases {
            lists[list] = lists[list]?.sorted { left, right in
                (left.start ?? .greatestFiniteMagnitude) < (right.start ?? .greatestFiniteMagnitude)
            }
        }

        return ComposedSummary(
            brief: edits.brief ?? summary.brief,
            summary: edits.summary ?? summary.summary,
            topics: edits.topics ?? summary.topics,
            decisions: lists[.decisions] ?? [],
            actionItems: lists[.actionItems] ?? [],
            openQuestions: lists[.openQuestions] ?? [],
            language: summary.language,
            isBriefEdited: edits.brief != nil,
            isSummaryEdited: edits.summary != nil,
            areTopicsEdited: edits.topics != nil
        )
    }

    private static func generatedItems(_ summary: MeetingSummary,
                                       _ list: SummaryEdits.List) -> [MeetingSummary.Item] {
        switch list {
        case .decisions: return summary.decisions
        case .actionItems: return summary.actionItems
        case .openQuestions: return summary.openQuestions
        }
    }

    private static func compose(_ item: MeetingSummary.Item?,
                                anchor: SummaryEdits.Anchor?,
                                edit: SummaryEdits.ItemEdit?,
                                list: SummaryEdits.List) -> ComposedItem {
        ComposedItem(
            id: edit.map { "edit-\($0.id.uuidString)" }
                ?? "gen-\(list.rawValue)-\(anchor?.start ?? 0)-\(anchor?.fingerprint ?? "")",
            list: edit?.list ?? list,
            text: edit?.text ?? item?.text ?? "",
            owner: edit?.owner ?? item?.owner,
            due: edit?.due ?? item?.due,
            dueDate: edit?.dueDate ?? item?.dueDate,
            dueTime: edit?.dueTime ?? item?.dueTime,
            start: edit?.start ?? item?.start ?? anchor?.start,
            isDone: edit?.done ?? false,
            isEdited: edit?.changesContent ?? false,
            origin: edit?.origin ?? .generated,
            exports: edit?.exports ?? [],
            editID: edit?.id,
            anchor: anchor,
            generated: item
        )
    }

    /// Pull the edit that belongs to this anchor out of the pool, so no two
    /// rows can claim the same one.
    private static func takeMatch(for anchor: SummaryEdits.Anchor,
                                  from pool: inout [SummaryEdits.ItemEdit]) -> SummaryEdits.ItemEdit? {
        let candidates = pool.indices.filter { index in
            guard let candidate = pool[index].anchor else { return false }
            return candidate.list == anchor.list
        }
        // An unchanged citation is the same item, whatever the wording.
        if let exact = candidates.first(where: { pool[$0].anchor?.fingerprint == anchor.fingerprint }) {
            return pool.remove(at: exact)
        }
        let near = candidates
            .filter { index in
                guard let candidate = pool[index].anchor else { return false }
                return abs(candidate.start - anchor.start) <= anchorTolerance
                    && similarity(candidate.fingerprint, anchor.fingerprint) >= anchorSimilarity
            }
            .min { left, right in
                let leftDelta = abs((pool[left].anchor?.start ?? 0) - anchor.start)
                let rightDelta = abs((pool[right].anchor?.start ?? 0) - anchor.start)
                return leftDelta < rightDelta
            }
        return near.map { pool.remove(at: $0) }
    }

    /// Word overlap, 0…1 (Jaccard). Deliberately crude: it only has to tell
    /// "the model reworded this line" from "this is a different line".
    static func similarity(_ left: String, _ right: String) -> Double {
        let leftWords = Set(left.split(separator: " "))
        let rightWords = Set(right.split(separator: " "))
        if leftWords.isEmpty || rightWords.isEmpty { return 0 }
        let union = leftWords.union(rightWords).count
        return union == 0 ? 0 : Double(leftWords.intersection(rightWords).count) / Double(union)
    }
}

// MARK: - Dates

/// Formatting for the resolved deadline. The stored value stays an ISO day
/// string — it is what the backend produced and what a reminder needs.
enum DueDate {
    static func date(from iso: String?, time: String? = nil) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        var components = DateComponents()
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        if let time {
            let clock = time.split(separator: ":").compactMap { Int($0) }
            if clock.count == 2 {
                components.hour = clock[0]
                components.minute = clock[1]
            }
        }
        return Calendar.current.date(from: components)
    }

    /// "5 Aug" / "Aug 5", by locale; time appended when one was stated.
    static func label(_ iso: String?, time: String? = nil) -> String? {
        guard let date = date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(time == nil ? "MMMd" : "MMMd HHmm")
        if time != nil, let withTime = self.date(from: iso, time: time) {
            return formatter.string(from: withTime)
        }
        return formatter.string(from: date)
    }
}
