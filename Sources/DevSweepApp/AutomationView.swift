import AppKit
import DevSweepCore
import SwiftUI

struct AutomationView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.ruleWeeklySweep) private var weeklySweep = false
    @AppStorage(SettingsKey.ruleAutoCleanCritical) private var autoCritical = false
    @AppStorage(SettingsKey.ruleRemoveUnavailableSims) private var removeSims = false
    @State private var allowAgents = SharedSettings.allowAgentClean
    @State private var keepList = SharedSettings.keepList
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                rule("Weekly sweep of stale projects", $weeklySweep, SettingsKey.lastWeeklySweep,
                     "Once a week, removes build folders of projects untouched for 30 days or more. Active projects are always skipped.")
                rule("Free space automatically when the disk is almost full", $autoCritical, SettingsKey.lastAutoClean,
                     "Below 5 GB free, runs the same safe clean as the menu bar button (Rebuilds only), at most once an hour.")
                rule("Remove unavailable simulators", $removeSims, SettingsKey.lastSimCleanup,
                     "Once a day, deletes simulator devices whose runtime is gone (they can no longer boot), with xcrun simctl.")
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules run while DevSweep is open (it can stay in the menu bar). Each run is listed in History below and reported in a notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(isOn: $allowAgents) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow AI agents to clean")
                        Text("Agents can always read disk status and plan a cleanup. With this on they may also run a clean, limited to Rebuilds items, never protected ones.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: allowAgents) { _, on in SharedSettings.allowAgentClean = on }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add DevSweep to Claude Code").font(.callout)
                    HStack {
                        Text(Self.claudeCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.claudeCommand, forType: .string)
                            copied = true
                        }
                        .secondaryGlassButton()
                    }
                    Text("Tools: disk_status, plan_cleanup, clean_safe. Other MCP clients: run \"\(Self.cliPath) mcp\" over stdio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("AI agents (MCP)")
            }

            Section("Always keep") {
                if keepList.isEmpty {
                    Text("Nothing yet. Use \"Always keep\" in an item's details to protect it from every clean.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(keepList.sorted(), id: \.self) { id in
                        HStack {
                            Image(systemName: "pin.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.items.first { $0.id == id }?.name ?? id)
                                Text(model.items.first { $0.id == id }?.detail ?? "Not found in the last scan")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Remove") {
                                if let item = model.items.first(where: { $0.id == id }) {
                                    model.setKept(item, false)
                                } else {
                                    SharedSettings.keepList.remove(id)
                                }
                                keepList = SharedSettings.keepList
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("History") {
                if model.history.isEmpty {
                    Text("No cleans yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.history) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: Self.symbol(for: entry.source)).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(ByteFormat.string(entry.freed)) freed · \(entry.items.count) items"
                                     + (entry.failures > 0 ? " · \(entry.failures) skipped" : ""))
                                Text("\(entry.source) · \(entry.items.prefix(3).joined(separator: ", "))\(entry.items.count > 3 ? "…" : "")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automation")
        .onAppear {
            keepList = SharedSettings.keepList
            allowAgents = SharedSettings.allowAgentClean
            model.history = CleanHistory.load(limit: 30)
        }
    }

    private func rule(_ title: String, _ binding: Binding<Bool>, _ lastKey: String, _ detail: String) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if binding.wrappedValue, let last = UserDefaults.standard.object(forKey: lastKey) as? Date {
                    Text("Last run \(RelativeDate.string(last))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func symbol(for source: String) -> String {
        if source == "mcp" { return "sparkles" }
        if source == "cli" { return "terminal" }
        if source.hasPrefix("rule") { return "clock.arrow.circlepath" }
        if source == "menu bar" || source == "notification" { return "menubar.rectangle" }
        return "macwindow"
    }

    /// The CLI shipped inside the app bundle, or the dev build next to it.
    static var cliPath: String {
        if let bundled = Bundle.main.url(forResource: "devsweep", withExtension: nil) { return bundled.path }
        return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("devsweep").path
    }

    static var claudeCommand: String { "claude mcp add devsweep -- \"\(cliPath)\" mcp" }
}
