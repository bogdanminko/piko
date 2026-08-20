import AppKit
import SwiftUI

/// Where a row goes when it leaves Piko.
///
/// Split out of the cards for the same reason editing was split out of
/// MeetingVM: it is one closed idea — the destinations menu, the links behind it,
/// and what opening one is allowed to claim afterwards — and the view was long
/// enough without it. See ExportControl for the menu's order, ExportKey for how
/// a send is recorded, and LinkTemplate for what a link actually is.
extension MeetingSummaryCards {
    func reloadLinks() {
        links = LinkTemplateStore.load()
        services = BuiltInLinkVisibility.calendars
        trackers = BuiltInLinkVisibility.trackers
    }

    /// The destinations, built once and used by both the right-click menu and
    /// the badge on the row.
    func destinations(_ item: ComposedItem) -> ExportDestinations {
        ExportDestinations(item: item,
                           links: links,
                           services: services,
                           trackers: trackers,
                           onSend: { onSend?($0, $1) },
                           onOpenWeb: openInWeb,
                           onOpenPreset: openPreset,
                           onOpenLink: openLink,
                           onManageLinks: { editingLinks = $0 })
    }

    /// A built-in tracker: nothing was configured, so there is nothing saved to
    /// open — the preset's own template is the link. Recorded under the preset's
    /// identity rather than a saved link's, so the badge still names it.
    func openPreset(_ item: ComposedItem, _ preset: LinkPreset) {
        guard let recording = meeting.selected else { return }
        let template = LinkTemplate(name: preset.name, kind: preset.kind,
                                    template: preset.template)
        guard let url = template.url(for: item, from: recording,
                                     context: meeting.manualContext(for: recording))
        else { return }
        open(url, as: ExportKey.preset(preset), named: preset.name, for: item)
    }

    /// For the people whose calendar lives in a browser tab rather than in an
    /// account the Mac is signed into. The service's own compose screen opens
    /// prefilled — including guests, which only it is allowed to invite.
    func openInWeb(_ item: ComposedItem, _ service: WebCalendarLink.Service) {
        guard let recording = meeting.selected,
              let url = WebCalendarLink.url(service, for: item, from: recording,
                                            context: meeting.manualContext(for: recording))
        else { return }
        open(url, as: ExportKey.web(service), named: service.title, for: item)
    }

    /// A saved link, calendar or tracker. Jira and Linear arrive here rather than
    /// through an API: their own screen opens with the row filled in, and nothing
    /// has left the Mac until the person on this side presses Create.
    func openLink(_ item: ComposedItem, _ link: LinkTemplate) {
        guard let recording = meeting.selected,
              let url = link.url(for: item, from: recording,
                                 context: meeting.manualContext(for: recording))
        else { return }
        if link.copiesText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ItemNote.pasteable(for: item, from: recording),
                                           forType: .string)
        }
        open(url, as: ExportKey.link(link), named: link.name, for: item)
        if link.copiesText, openNote == nil {
            openNote = OpenNote(
                title: "\(link.name) is open — the row is on your clipboard",
                message: "Its create screen takes no details through a URL, so there was nothing "
                    + "to prefill. Paste into the summary: the first line is the text, the rest is "
                    + "the citation and the link back into the recording."
            )
        }
    }

    /// The row remembers where it was opened — "opened", not "created": the
    /// compose screen is prefilled, and pressing Create belongs to the other app.
    ///
    /// A scheme nothing on this Mac answers gets said out loud. `things:///add`
    /// without Things installed fails silently, which is the exact bug the send
    /// affordance was rebuilt to stop shipping.
    private func open(_ url: URL, as target: String, named name: String,
                      for item: ComposedItem) {
        guard NSWorkspace.shared.open(url) else {
            let isApp = url.scheme?.lowercased().hasPrefix("http") != true
            openNote = OpenNote(
                title: "Nothing opened it",
                message: "Nothing on this Mac opened \(name). "
                    + (isApp ? "The app has to be installed for its link to work."
                             : "Check the link's URL.")
            )
            return
        }
        meeting.recordExport("", target: target, for: item)
    }
}
