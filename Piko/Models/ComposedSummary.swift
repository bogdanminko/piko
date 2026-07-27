import Foundation

/// A summary as the screen shows it: what the model produced with the user's
/// overlay applied.
///
/// Kept apart from `SummaryEdits` because the two are opposite halves of the
/// same idea — that file is what is stored, this one is what is rendered, and
/// nothing here is ever written to disk. `ComposedSummary.make` is the only
/// bridge between them.

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
    /// The tracker parent this row goes under, its own or the meeting's.
    var epic: String?
    /// True when `epic` is the meeting's default rather than this row's answer
    /// — shown quietly, so "all of them" does not read as "this one".
    var isEpicInherited: Bool = false
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
    /// The epic every action item inherits, shown on the card's header so the
    /// answer is stated once where it is set rather than repeated on each row.
    var defaultEpic: String?

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
                rows.append(compose(item, anchor: anchor, edit: matched, list: list,
                                    defaults: edits.defaults))
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
                                                    list: list, defaults: edits.defaults))
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
            defaultEpic: edits.defaults?.epic?.nonEmpty,
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
                                list: SummaryEdits.List,
                                defaults: SummaryEdits.Defaults?) -> ComposedItem {
        // The epic falls back to the meeting's rather than to the model's:
        // nobody says a Jira key out loud, so there is never a generated one.
        let epic = SummaryEdits.override(edit?.epic, defaults?.epic?.nonEmpty)
        return ComposedItem(
            id: edit.map { "edit-\($0.id.uuidString)" }
                ?? "gen-\(list.rawValue)-\(anchor?.start ?? 0)-\(anchor?.fingerprint ?? "")",
            list: edit?.list ?? list,
            text: edit?.text ?? item?.text ?? "",
            owner: SummaryEdits.override(edit?.owner, item?.owner),
            due: SummaryEdits.override(edit?.due, item?.due),
            dueDate: SummaryEdits.override(edit?.dueDate, item?.dueDate),
            dueTime: SummaryEdits.override(edit?.dueTime, item?.dueTime),
            epic: epic,
            isEpicInherited: edit?.epic == nil && epic != nil,
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
    /// "yyyy-MM-dd" — the shape the backend writes and every export reads.
    /// POSIX rather than the user's locale, because this is stored, not shown.
    static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "HH:mm", 24-hour whatever the Mac's clock is set to display — the value
    /// is parsed back by `date(from:time:)`, not read by a person.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

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
