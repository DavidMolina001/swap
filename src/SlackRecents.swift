// The Slack chats Swap lists: the ones you actually use. Nothing here touches the network and no sign-in exists.
// Slack's own window gives the team and open chat (its address) and the unread marks (its sidebar), read through
// Accessibility; chats open with Slack's documented slack:// links. Names and ids only, never message text.
// Stored in the preferences file only while Return expands apps is on, and gone when it goes off or clearSaved runs.
import AppKit

enum SlackRecents {
    private static let shown = 6, kept = 50, seedSize = 12
    struct Team: Codable, Equatable {
        let id: String; let name: String
        // Workspaces of one Enterprise org share an id (E…), so there the name tells them apart.
        var key: String { id.hasPrefix("E") ? id + "/" + name : id }
    }
    struct Chat: Codable, Equatable { let id: String; var title: String; let kind: String }   // id = conversation id

    private static let d = UserDefaults.standard
    private(set) static var teams: [Team] = stored("slackTeams") ?? []
    private static var recents: [String: [Chat]] = stored("slackRecents") ?? [:]   // team key -> chats, newest first
    private static var unread: [String: [String: Int]] = [:]                      // team key -> conversation id -> unread
    private static var sidebar: [String: [Chat]] = [:]                            // team key -> rows seen in Slack just now
    private static var renames: [String: String] = [:]                            // team id -> new name seen once

    private static func stored<T: Decodable>(_ key: String) -> T? { d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func save<T: Encodable>(_ v: T, _ key: String) { if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) } }

    static func team(named name: String) -> Team? { teams.first { SlackRows.matches($0.name, name) } }

    // Forgets every Slack chat and workspace Swap saved, in memory and in the preferences file. For the Settings
    // button. `pins: false` keeps Slack pins, for Return expands apps going off: those are the user's own choice.
    static func clearSaved(pins: Bool = true) {
        teams = []; recents = [:]; unread = [:]; sidebar = [:]; renames = [:]
        d.removeObject(forKey: "slackTeams")
        d.removeObject(forKey: "slackRecents")
        SlackRows.forgetUse()
        guard pins else { return }
        let kept = Settings.pins.compactMapValues { list -> [String]? in
            let left = list.filter { !$0.hasPrefix("slack:") }
            return left.isEmpty ? nil : left
        }
        if kept != Settings.pins { Settings.pins = kept }
    }

    // Slack pins, whichever group they were filed under: their ids carry the team.
    static func pins() -> [String] { Settings.pins.values.flatMap { $0 }.filter { $0.hasPrefix("slack:") } }

    // Which team this read belongs to, or nil to throw the read away. The title's name and the address's team must
    // agree with each other, with Slack's own workspace menu and with what is already known. A name that moved to
    // another id, or a new name for a known team, is what a switch in progress looks like: a real rename is believed
    // only when a later read says the same.
    private static func verifiedTeam(_ s: SlackSource.Snapshot) -> Team? {
        let name = SlackRows.workspace(named: s.workspace)?.name ?? s.workspace
        guard SlackRows.workspaces.isEmpty || SlackRows.workspace(named: name) != nil else { return nil }
        let enterprise = s.team.hasPrefix("E")
        if let same = teams.first(where: { $0.id == s.team && SlackRows.matches($0.name, name) }) {
            renames[s.team] = nil
            guard same.name != name else { return same }   // the menu's short name gives way to the title's full one
            let full = Team(id: s.team, name: name)
            replace(same, with: full)
            return full
        }
        guard !teams.contains(where: { SlackRows.matches($0.name, name) }) else { return nil }
        if let old = teams.first(where: { $0.id == s.team }), !enterprise {
            guard renames[s.team] == name else { renames[s.team] = name; return nil }
            renames[s.team] = nil
            let new = Team(id: s.team, name: name)
            replace(old, with: new)
            return new
        }
        let new = Team(id: s.team, name: name)
        teams.append(new)
        save(teams, "slackTeams")
        return new
    }

    private static func replace(_ old: Team, with new: Team) {
        teams.removeAll { $0 == old }
        teams.append(new)
        save(teams, "slackTeams")
        if old.key != new.key, let list = recents.removeValue(forKey: old.key) { recents[new.key] = list }
    }

    // What Slack is showing now, already proved self-consistent by SlackSource.snapshot: learns the team, moves the
    // open chat up, refreshes unread marks, seeds a new list. Does nothing while the feature is off.
    static func absorb(_ s: SlackSource.Snapshot) {
        guard Settings.drillIn, !s.rows.isEmpty, let team = verifiedTeam(s) else { return }
        var list = recents[team.key] ?? []
        sidebar[team.key] = s.rows.map { Chat(id: $0.conversation, title: $0.item.title, kind: $0.item.detail) }
        unread[team.key] = Dictionary(s.rows.map { ($0.conversation, $0.item.unread) }, uniquingKeysWith: { a, _ in a })
        if list.isEmpty {
            list = s.rows.prefix(seedSize).map { Chat(id: $0.conversation, title: $0.item.title, kind: $0.item.detail) }
        }
        for r in s.rows { if let i = list.firstIndex(where: { $0.id == r.conversation }) { list[i].title = r.item.title } }
        if let open = s.rows.first(where: { $0.conversation == s.conversation }) { list = used(open.conversation, open.item.title, open.item.detail, in: list) }
        guard list != recents[team.key] else { return }
        recents[team.key] = list
        save(recents, "slackRecents")
    }

    private static func used(_ id: String, _ title: String, _ kind: String, in list: [Chat]) -> [Chat] {
        if list.first?.id == id { return list }
        var out = list.filter { $0.id != id }
        out.insert(Chat(id: id, title: title, kind: kind), at: 0)
        return Array(out.prefix(kept))
    }

    private static func rowID(_ team: Team, _ c: Chat) -> String { "slack:\(team.id):\(c.kind):\(c.id)" }

    // Unread first, then pinned, then the 6 used last.
    static func items(_ team: Team, pins: [String]) -> [ChildItem] {
        let list = recents[team.key] ?? [], seen = sidebar[team.key] ?? [], marks = unread[team.key] ?? [:]
        func row(_ c: Chat) -> ChildItem { ChildItem(id: rowID(team, c), title: c.title, detail: c.kind, icon: nil, active: false, unread: marks[c.id] ?? 0) }
        var out = Array(seen.filter { (marks[$0.id] ?? 0) > 0 }.prefix(shown)).map(row)   // a busy workspace can't flood the list
        for p in pins where !out.contains(where: { $0.id == p }) { if let c = (list + seen).first(where: { rowID(team, $0) == p }) { out.append(row(c)) } }
        var added = 0
        for c in list where added < shown && !out.contains(where: { $0.id == rowID(team, c) }) { out.append(row(c)); added += 1 }
        return out
    }

    // Everything needed to open a row, checked: these ids came out of another app's interface and go into a link.
    private static func link(_ query: [URLQueryItem], host: String) -> URL? {
        var c = URLComponents(); c.scheme = "slack"; c.host = host; c.queryItems = query
        return c.url
    }

    // Called on the provider's queue. The list itself belongs to the main thread.
    static func open(_ child: ChildItem) {
        let parts = child.id.split(separator: ":", maxSplits: 3).map(String.init)   // slack, team, kind, conversation
        guard parts.count == 4, SlackSource.isTeamID(parts[1]), SlackSource.isConversationID(parts[3]) else { return }
        DispatchQueue.main.async {
            guard Settings.drillIn, let key = recents.keys.first(where: { ($0 == parts[1] || $0.hasPrefix(parts[1] + "/")) && recents[$0]?.contains { $0.id == parts[3] } == true }) else { return }
            recents[key] = used(parts[3], child.title, parts[2], in: recents[key] ?? [])
            save(recents, "slackRecents")
        }
        SlackSource.expect(.init(team: parts[1], conversation: parts[3]))
        // slack://channel for DMs too: slack://user opens the person's profile instead of the conversation.
        if let url = link([URLQueryItem(name: "team", value: parts[1]), URLQueryItem(name: "id", value: parts[3])], host: "channel") { NSWorkspace.shared.open(url) }
    }
    static func openWorkspace(_ team: Team) {
        guard SlackSource.isTeamID(team.id), let url = link([URLQueryItem(name: "team", value: team.id)], host: "open") else { return }
        NSWorkspace.shared.open(url)
    }
}
