import Foundation

/// The half of `LinkParser` that recognises a service from its address alone.
///
/// Split from the shape-based reading next door because the two answer different
/// questions: this one knows what Outlook, Jira and GitLab URLs look like, the
/// other knows what a date or a guest list looks like in a URL it has never seen.
/// Members are internal rather than private only because they now live in a
/// second file.
extension LinkParser {
    // MARK: - Services whose format is known

    /// This is what makes a corporate Exchange usable: nobody can get a "create
    /// event" link out of on-premise OWA, but its compose parameters are the
    /// standard ones, so knowing the host is enough.
    static func knownCalendar(_ components: URLComponents) -> String? {
        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        let fields = "subject={title}&startdt={start}&enddt={end}&body={details}"
            + "&location={location}&to={guests}"

        // On-premise OWA: https://mail.company.com/owa/…
        if path.hasPrefix("/owa") || path.contains("/owa/") {
            return "https://\(host)/owa/?path=/calendar/action/compose&rru=addevent&\(fields)"
        }
        if host.hasSuffix("outlook.office.com") || host.hasSuffix("outlook.office365.com")
            || host.hasSuffix("outlook.live.com") {
            return "https://\(host)/calendar/0/deeplink/compose"
                + "?path=/calendar/action/compose&rru=addevent&\(fields)"
        }
        if host.hasSuffix("calendar.google.com") {
            return "https://calendar.google.com/calendar/render?action=TEMPLATE"
                + "&text={title}&dates={start_basic}/{end_basic}"
                + "&details={details}&location={location}&add={guests}"
        }
        return nil
    }

    /// The same idea one level up: *any* URL from these trackers is enough,
    /// because the coordinates a create link needs — the repository, the team,
    /// the project — are in the addresses people already have open. Jira is the
    /// one exception, and it says so instead of failing quietly.
    static func knownTracker(_ components: URLComponents) -> Reading {
        let host = components.host?.lowercased() ?? ""
        let path = components.path
        let segments = path.split(separator: "/").map(String.init)

        if let scheme = components.scheme?.lowercased(),
           let preset = LinkPreset.all.first(where: { $0.scheme == scheme }) {
            return .ready(template: preset.template, name: preset.name)
        }
        if isJira(host: host, path: path.lowercased()) {
            return jira(components, host: host)
        }
        // GitLab before GitHub: a self-hosted instance can live on any host, and
        // `/-/` in the path is its unmistakable signature.
        if host.contains("gitlab") || path.contains("/-/") {
            return gitlab(host: host, path: path)
        }
        if host.contains("github"), segments.count >= 2 {
            return .ready(template: LinkPreset.github.resolved([
                "{owner}": segments[0], "{repo}": segments[1]
            ]), name: LinkPreset.github.name)
        }
        if host.hasSuffix("linear.app") {
            return linear(segments)
        }
        if host.hasSuffix("trello.com") {
            return .ready(template: LinkPreset.trello.template, name: LinkPreset.trello.name)
        }
        return .unrecognised
    }

    /// An issue key in a path: `/browse/ABC-123`, possibly under a context path.
    /// This is the shape of the link people actually copy, and on a self-hosted
    /// Jira it is the *only* signal — the host is whatever the company called it.
    static let issuePath = #//browse/[A-Za-z][A-Za-z0-9_]*-\d+/#

    /// Cloud sits on atlassian.net; Server and Data Center sit on
    /// `jira.company.com`, `company.com/jira`, or anything else, so several
    /// signals are needed and any one of them is enough.
    static func isJira(host: String, path: String) -> Bool {
        host.hasSuffix("atlassian.net")
            || host.contains("jira")
            || path.contains("/secure/createissue")
            || path.contains("/jira/")
            || path.contains("/plugins/servlet/")
            || path.contains(issuePath)
    }

    /// Jira cannot be prefilled from a project *key*: `pid` and `issuetype` are
    /// numeric ids, on Cloud as much as on Server, and there is no endpoint that
    /// takes the key instead. So either the pasted URL already carries both — the
    /// address bar does after picking a project on the create screen — or this
    /// hands over the page that produces one.
    static func jira(_ components: URLComponents, host: String) -> Reading {
        let base = jiraBase(host: host, path: components.path)
        let query = parameters(components)
        if let pid = query["pid"], let type = query["issuetype"] {
            return .ready(template: LinkPreset.jiraTemplate(base: base, pid: pid, issuetype: type),
                          name: LinkPreset.jira.name)
        }
        // No ids in the link, so this saves the create screen itself. It opens
        // where the row can be typed, with the row already on the clipboard —
        // and the sheet says how to trade that for a real prefill.
        return .copyPaste(template: "\(base)/secure/CreateIssue!default.jspa",
                          name: LinkPreset.jira.name,
                          prefill: ["{base}": base])
    }

    /// On-premise Jira is often mounted under a context path
    /// (`company.com/jira/browse/ABC-1`). Everything before the part that
    /// identified it as Jira belongs to the base, or the create URL 404s.
    static func jiraBase(host: String, path: String) -> String {
        let lower = path.lowercased()
        for marker in ["/secure/", "/browse/", "/plugins/servlet/", "/jira/"] {
            guard let range = lower.range(of: marker) else { continue }
            return "https://\(host)\(path[path.startIndex..<range.lowerBound])"
        }
        return "https://\(host)"
    }

    /// `https://host/group/subgroup/project/-/issues/new`. The project path is
    /// everything before `/-/`, which is also how GitLab itself reads its URLs,
    /// so nested subgroups come out right.
    static func gitlab(host: String, path: String) -> Reading {
        let project: String
        if let marker = path.range(of: "/-/") {
            project = String(path[path.startIndex..<marker.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            project = path.split(separator: "/").map(String.init).joined(separator: "/")
        }
        guard project.contains("/") else {
            return .incomplete(
                name: LinkPreset.gitlab.name,
                why: "That address names a group, not a project. Open any issue or the project's "
                    + "own page and paste that instead.",
                next: nil,
                prefill: ["{base}": "https://\(host)"]
            )
        }
        return .ready(template: LinkPreset.gitlab.resolved([
            "{base}": "https://\(host)", "{project}": project
        ]), name: LinkPreset.gitlab.name)
    }

    static func linear(_ segments: [String]) -> Reading {
        guard let workspace = segments.first, let team = linearTeam(segments) else {
            return .incomplete(
                name: LinkPreset.linear.name,
                why: "The team is not in that address. Open any issue — "
                    + "linear.app/<workspace>/issue/ENG-123 — and paste that instead.",
                next: nil,
                prefill: segments.first.map { ["{workspace}": $0] } ?? [:]
            )
        }
        return .ready(template: LinkPreset.linear.resolved([
            "{workspace}": workspace, "{team}": team
        ]), name: LinkPreset.linear.name)
    }

    /// linear.app/<workspace>/issue/ENG-12 and …/team/ENG/… both name the team.
    static func linearTeam(_ segments: [String]) -> String? {
        if let index = segments.firstIndex(of: "team"), segments.count > index + 1 {
            return segments[index + 1]
        }
        if let index = segments.firstIndex(of: "issue"), segments.count > index + 1 {
            return segments[index + 1].split(separator: "-").first.map(String.init)
        }
        return nil
    }

    static func parameters(_ components: URLComponents) -> [String: String] {
        Dictionary(
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name.lowercased(), $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
