// What each app adds to Settings > Inside apps. The pane loops over Children.sources and names no app, so a new
// provider adds its settings here and the pane stays as it is. A provider with no settings declares nothing.
// These extensions belong in the providers' own files; they sit here until those files have an owner free to take them.
import SwiftUI

enum ProviderRow {
    case toggle(title: String, help: String? = nil, isOn: Binding<Bool>, enabled: Bool = true)
    case heading(String)
    case note(title: String, value: String)
    case action(title: String, help: String, run: () -> Void)
}

struct ProviderSection {
    let title: String
    var footer: String? = nil
    let rows: [ProviderRow]
}

protocol ProviderSettings {
    static var settingsSection: ProviderSection { get }
}

// The dimmed row's help: says why, and where the switch is.
let needsInsideApps = "Needs Show tabs and chats inside apps, above."

extension SlackSource: ProviderSettings {
    static var settingsSection: ProviderSection {
        var rows: [ProviderRow] = [
            .toggle(title: "One row per workspace", help: "Each workspace sits in the list by when you last used it.",
                    isOn: Binding(get: { Settings.slackWorkspaces }, set: { Settings.slackWorkspaces = $0 })),
        ]
        let names = SlackRows.workspaces.map { $0.name }
        if names.isEmpty {
            rows.append(.note(title: "Workspaces", value: "Open Slack to list them"))
        } else {
            rows.append(.heading("Show these workspaces"))
            rows += names.map { name in
                .toggle(title: name, isOn: Binding(get: { !Settings.slackHidden.contains(name) }, set: { shown in
                    var hidden = Settings.slackHidden.filter { $0 != name }
                    if !shown { hidden.append(name) }
                    Settings.slackHidden = hidden
                }), enabled: Settings.slackWorkspaces)
            }
        }
        rows.append(.action(title: "Clear saved chats", help: "Forgets the Slack chat names, ids, last used times and Slack pins kept on this Mac.") {
            SlackRecents.clearSaved()
        })
        return ProviderSection(title: "Slack", rows: rows)
    }
}

extension WhatsAppSource: ProviderSettings {
    static var settingsSection: ProviderSection {
        ProviderSection(title: "WhatsApp", footer: "Reads your chat list on this Mac. WhatsApp does not endorse this and its terms are broad.", rows: [
            .toggle(title: "Show WhatsApp chats", help: Settings.drillIn ? "Return on WhatsApp lists your recent chats. Off until you switch it on." : needsInsideApps,
                    isOn: Binding(get: { Settings.whatsappChats }, set: { Settings.whatsappChats = $0 }), enabled: Settings.drillIn),
            .toggle(title: "Show Archived", help: Settings.drillIn && Settings.whatsappChats ? "An Archived row above your chats." : "Needs Show WhatsApp chats.",
                    isOn: Binding(get: { Settings.whatsappArchive }, set: { Settings.whatsappArchive = $0 }), enabled: Settings.drillIn && Settings.whatsappChats),
        ])
    }
}
