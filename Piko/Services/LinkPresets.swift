import Foundation

/// Recipes for a saved link, not destinations of their own.
///
/// Google Calendar can be built in because its compose URL is the same for
/// everybody. No tracker is: Jira needs your site and the numeric ids of the
/// project and issue type, GitHub needs the repository, Linear needs the team.
/// So a tracker is not a service Piko ships with — it is a template with holes
/// where your own coordinates go, filled in once and then saved like any pasted
/// link. That is also why there is no "Connect Jira" button: there is nothing to
/// connect to, no token to store, and nothing leaves the Mac until you press
/// Create on the tracker's own screen.
///
/// The other route to the same saved link is pasting a URL your tracker
/// produced — see LinkParser. Presets exist for the people who would rather not
/// go hunting for one.
struct LinkPreset: Identifiable {
    var id: String { name }
    let name: String
    /// Stable slug, used as the key a `Person`'s handle for this tracker is
    /// stored under. Separate from `name` because the name is what a user may
    /// rename their saved link to, and a renamed link must not orphan the ids.
    let service: String
    let kind: LinkKind
    /// Holds two sorts of hole: setup fields, filled in once when the link is
    /// added, and the placeholders of `LinkTemplate`, filled in on every send.
    let template: String
    let fields: [Field]
    /// Where to find the answers. A preset asking for a number nobody can locate
    /// is worse than no preset.
    let hint: String
    /// The host a pasted link of this service ends with, so one can be
    /// recognised by name. Stated rather than read out of `template`: a template
    /// with `{site}` in the host is not a parsable URL until it is filled in.
    var domain: String?

    /// A link opened through the app's own scheme needs that app installed;
    /// the web ones work on any Mac.
    var needsApp: Bool { !template.lowercased().hasPrefix("http") }

    /// `things`, `todoist`, `omnifocus` — nil for the web ones, deliberately:
    /// matching a pasted link on the scheme `https` would match everything.
    var scheme: String? {
        guard needsApp else { return nil }
        return template.components(separatedBy: ":").first?.lowercased()
    }

    /// Nothing to fill in, so it can be offered the way Google Calendar is:
    /// present in the menu from the start, clicked, opened. Trello asks which
    /// board on its own screen; Things, Todoist and OmniFocus are apps on this
    /// Mac and need no address at all.
    var isReady: Bool { fields.isEmpty }

    /// One identity for the preset, used both for hiding it from the menu and for
    /// recording that a row was opened in it. The two must agree — a preset
    /// renamed in the menu would otherwise orphan every badge pointing at it.
    var visibilityID: String { "preset:\(name)" }

    struct Field: Identifiable {
        var id: String { token }
        let token: String
        let label: String
        let placeholder: String
        var value: FieldValue = .text
        var isOptional = false
    }

    /// How a typed answer is read. `baseURL` exists because "where does your Jira
    /// live" has two right answers — a Cloud site name and a self-hosted address
    /// — and a field that only accepts one of them is wrong for everybody on the
    /// other side.
    enum FieldValue {
        case text
        /// A bare word with no dot in it is a subdomain of `bareDomain`, when the
        /// service has such a shorthand at all. Nil means it does not, and a bare
        /// word is then simply a host.
        case baseURL(bareDomain: String?)
    }

    /// `acme` → `https://acme.atlassian.net` (with `bareDomain`),
    /// `jira.company.com` → `https://jira.company.com`, and anything already
    /// spelled out is left alone, trailing slash removed. A dot is the tell:
    /// Cloud site names cannot contain one, hosts always do.
    ///
    /// A path survives, because plenty of on-premise instances live under one
    /// (`company.com/jira`) and dropping it would build a URL that 404s.
    static func normalizedBase(_ raw: String, bareDomain: String?) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return "" }
        if text.lowercased().hasPrefix("http") { return text }
        if let bareDomain, !text.contains("."), !text.contains("/") {
            return "https://\(text).\(bareDomain)"
        }
        return "https://\(text)"
    }

    /// The template with the setup answers baked in. An unanswered optional
    /// field takes its whole query parameter with it, so `labels=` never reaches
    /// a tracker that would read it as a label named "".
    func resolved(_ answers: [String: String]) -> String {
        var text = template
        for field in fields where field.isOptional && (answers[field.token]?.isEmpty ?? true) {
            text = LinkTemplate.dropParameter(containing: field.token, from: text)
        }
        for field in fields {
            let typed = (answers[field.token] ?? "").trimmingCharacters(in: .whitespaces)
            let answer = switch field.value {
            case .text: typed
            case .baseURL(let bareDomain): LinkPreset.normalizedBase(typed, bareDomain: bareDomain)
            }
            text = text.replacingOccurrences(of: field.token, with: answer)
        }
        return text
    }

    /// Everything still unanswered — the Add button waits on this being empty.
    func missing(_ answers: [String: String]) -> [Field] {
        fields.filter { !$0.isOptional && (answers[$0.token]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
    }

    static func named(_ name: String) -> LinkPreset? {
        all.first { $0.name == name }
    }

    /// The trackers whose create URL takes an assignee at all. Only these get a
    /// field in the People editor — asking for somebody's Trello id when no
    /// Trello link can carry one is a form that does nothing.
    ///
    /// GitLab and Linear are absent on purpose: both want a numeric or UUID id
    /// that is not visible anywhere in their UI, so the field would be one
    /// nobody could fill in.
    static var assigneeServices: [LinkPreset] { [jira, github] }

    /// Which known tracker a saved template points at, by scheme or host.
    /// Self-hosted Jira and GitLab are recognised the same way the parser does
    /// it — the host is whatever the company called it, so the shape has to say.
    static func service(forTemplate template: String) -> String? {
        guard let components = URLComponents(string: template) else { return nil }
        if let scheme = components.scheme?.lowercased(),
           let match = all.first(where: { $0.scheme == scheme }) {
            return match.service
        }
        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        if LinkParser.isJira(host: host, path: path) { return jira.service }
        if host.contains("gitlab") || path.contains("/-/") { return gitlab.service }
        if let match = all.first(where: { preset in
            guard let domain = preset.domain else { return false }
            return host == domain || host.hasSuffix(".\(domain)")
        }) {
            return match.service
        }
        // GitHub Enterprise lives on the company's own host, same as the parser
        // reads it.
        return host.contains("github") ? github.service : nil
    }

    static let all: [LinkPreset] = [jira, github, gitlab, linear, trello, todoist, things, omniFocus]

    /// Offered directly in the menu, no setup screen involved.
    static var builtIn: [LinkPreset] { all.filter(\.isReady) }

    /// The ones that need the user's own coordinates before they mean anything.
    static var configurable: [LinkPreset] { all.filter { !$0.isReady } }

    /// The one place Jira's create-issue URL shape is written down — the preset
    /// and `LinkParser` both build from here, so they cannot drift apart.
    ///
    /// `epicField` is the name of the custom field the epic goes in, and it is
    /// a per-instance number rather than a constant: Cloud calls it
    /// `customfield_10014` more often than not, Server whatever it was created
    /// as. Empty when nobody has said which — the parser path has no way to
    /// know, and a guessed field name would either be ignored or rejected.
    static func jiraTemplate(base: String, pid: String, issuetype: String,
                             epicField: String = "") -> String {
        var text = "\(base)/secure/CreateIssueDetails!init.jspa"
            + "?pid=\(pid)&issuetype=\(issuetype)&summary={title}&description={details}"
            + "&duedate={due_date}&assignee={assignee}"
        if !epicField.isEmpty { text += "&\(epicField)={epic}" }
        return text
    }

    /// Jira's oldest create-issue URL, and still the one that prefills. It wants
    /// numeric ids rather than the project key, which is the one awkward part of
    /// this whole feature — hence the hint, which is the shortest honest route to
    /// those two numbers.
    static let jira = LinkPreset(
        name: "Jira",
        service: "jira",
        kind: .task,
        template: jiraTemplate(base: "{base}", pid: "{pid}", issuetype: "{issuetype}",
                               epicField: "{epicfield}"),
        fields: [
            Field(token: "{base}", label: "Site or address",
                  placeholder: "acme — or jira.company.com",
                  value: .baseURL(bareDomain: "atlassian.net")),
            Field(token: "{pid}", label: "Project id", placeholder: "10001"),
            Field(token: "{issuetype}", label: "Issue type id", placeholder: "10002"),
            Field(token: "{epicfield}", label: "Epic field",
                  placeholder: "customfield_10014 (optional)", isOptional: true)
        ],
        hint: "A bare name is read as a Cloud site (acme → acme.atlassian.net); anything with a dot "
            + "in it is used as it stands, so a self-hosted Jira goes in whole. For the two numbers, "
            + "open <your Jira>/secure/CreateIssue!default.jspa, pick the project and the issue "
            + "type, press Next — both are then in the address bar, and pasting that URL above "
            + "fills in all three fields at once. The epic field is the custom field id your "
            + "instance keeps Epic Link in — leave it out and the epic goes into the description "
            + "instead of its own field.",
        domain: "atlassian.net"
    )

    static let github = LinkPreset(
        name: "GitHub Issues",
        service: "github",
        kind: .task,
        template: "https://github.com/{owner}/{repo}/issues/new"
            + "?title={title}&body={details}&labels={labels}&assignees={assignee}",
        fields: [
            Field(token: "{owner}", label: "Owner", placeholder: "acme"),
            Field(token: "{repo}", label: "Repository", placeholder: "backend"),
            Field(token: "{labels}", label: "Labels", placeholder: "meeting (optional)", isOptional: true)
        ],
        hint: "Owner and repository are the two parts of the repo's address. Labels are optional and "
            + "comma-separated; they have to exist in the repo already.",
        domain: "github.com"
    )

    /// GitLab prefills issues by URL on gitlab.com *and* on any self-hosted
    /// instance, which is why the host is a field rather than a constant.
    ///
    /// The brackets in `issue[title]` are written percent-encoded because raw `[`
    /// and `]` are not legal in a query (RFC 3986 reserves them for the host).
    /// Foundation's `URL(string:)` happens to accept them today, so this is
    /// belt-and-braces rather than a fix for a live bug — but a template only
    /// fails at send time, long after it looked fine in the editor, and that is
    /// not a failure worth depending on parser leniency to avoid. GitLab reads
    /// them decoded either way.
    static let gitlab = LinkPreset(
        name: "GitLab",
        service: "gitlab",
        kind: .task,
        template: "{base}/{project}/-/issues/new"
            + "?issue%5Btitle%5D={title}&issue%5Bdescription%5D={details}",
        fields: [
            Field(token: "{base}", label: "Host or address", placeholder: "gitlab.com",
                  value: .baseURL(bareDomain: nil)),
            Field(token: "{project}", label: "Project path", placeholder: "acme/backend")
        ],
        hint: "The project path is everything between the host and the `/-/` in any of its "
            + "addresses — subgroups included.",
        domain: "gitlab.com"
    )

    static let linear = LinkPreset(
        name: "Linear",
        service: "linear",
        kind: .task,
        template: "https://linear.app/{workspace}/team/{team}/new"
            + "?title={title}&description={details}",
        fields: [
            Field(token: "{workspace}", label: "Workspace", placeholder: "acme"),
            Field(token: "{team}", label: "Team key", placeholder: "ENG")
        ],
        hint: "Both are in the address of any Linear issue: linear.app/<workspace>/issue/<TEAM>-123.",
        domain: "linear.app"
    )

    /// Trello takes no board or list in the URL — it asks on its own screen —
    /// so this one is ready as it stands.
    static let trello = LinkPreset(
        name: "Trello",
        service: "trello",
        kind: .task,
        template: "https://trello.com/add-card?name={title}&desc={details}",
        fields: [],
        hint: "Trello asks which board and list on its own screen, so there is nothing to set up.",
        domain: "trello.com"
    )

    static let todoist = LinkPreset(
        name: "Todoist",
        service: "todoist",
        kind: .task,
        template: "todoist://addtask?content={title}&description={details}&date={due_date}",
        fields: [],
        hint: "Goes straight to the Todoist app on this Mac — it has no prefillable web address."
    )

    static let things = LinkPreset(
        name: "Things",
        service: "things",
        kind: .task,
        template: "things:///add?title={title}&notes={details}&deadline={due_date}",
        fields: [],
        hint: "Opens Things on this Mac with the task filled in, deadline included."
    )

    static let omniFocus = LinkPreset(
        name: "OmniFocus",
        service: "omnifocus",
        kind: .task,
        template: "omnifocus:///add?name={title}&note={details}&due={due_date}",
        fields: [],
        hint: "Opens OmniFocus on this Mac with the task filled in."
    )
}
