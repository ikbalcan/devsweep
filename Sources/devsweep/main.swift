import DevSweepCore
import Foundation

let usage = """
devsweep: safe disk cleanup for developers

USAGE
  devsweep status                       Free space and what can be freed, per tier
  devsweep scan [--json]                Everything DevSweep found, grouped by area
                                        (add --full to re-measure every folder; otherwise
                                        unchanged folders reuse their size for up to a day)
  devsweep clean --tier rebuilds [--dry-run] [--yes]
                                        Remove every unprotected item of that tier
  devsweep clean --tier redownload [--dry-run] [--yes] [--delete]
                                        Re-download items go to the Trash unless --delete
  devsweep history                      Recent cleans, from the app, the CLI, agents and rules
  devsweep mcp                          Run as an MCP server over stdio, for AI agents

Tiers
  rebuilds     comes back on the next build or install (deleted outright)
  redownload   no data loss, but needs internet again (moved to Trash by default)
  has-data     may hold your data: only from the DevSweep app, one by one

Active projects, running simulators/emulators and running Gradle are always skipped.
"""

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { args.contains(name) }
func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func scan() async -> ScanResult {
    if !flag("--json") { FileHandle.standardError.write(Data("Scanning…\n".utf8)) }
    let start = Date()
    let timing = ProcessInfo.processInfo.environment["DEVSWEEP_TIMING"] != nil
    let r = await Scanner().scan(reuseSizes: !flag("--full")) { event in
        guard timing, case .stepFinished(let id, let items, _) = event else { return }
        FileHandle.standardError.write(Data(String(format: "  %6.1f s  %@ (%d)\n", Date().timeIntervalSince(start), id, items).utf8))
    }
    ScanCache.save(r)
    return r
}

func printStatus(_ r: ScanResult) {
    let level: String
    switch LowDiskPolicy().level(r.disk.available) {
    case .ok: level = "ok"
    case .low: level = "low"
    case .critical: level = "critical"
    }
    print("Free \(ByteFormat.string(r.disk.available)) of \(ByteFormat.string(r.disk.total))   \(level)")
    for t in Tier.allCases {
        let items = r.items.filter { $0.tier == t }
        let free = items.filter { !$0.isProtected }.reduce(0) { $0 + $1.size }
        print("  \(pad(t.title, 12)) \(lpad(ByteFormat.string(r.total(tier: t)), 9))   \(ByteFormat.string(free)) cleanable now")
    }
    print("Safe to free now: \(ByteFormat.string(r.safeSelection.reduce(0) { $0 + $1.size })) (devsweep clean --tier rebuilds)")
}

let command = args.first ?? "help"
switch command {
case "status":
    let r = await scan()
    if flag("--json") {
        let tiers = Dictionary(uniqueKeysWithValues: Tier.allCases.map { ($0.rawValue, r.total(tier: $0)) })
        let obj: [String: Any] = ["free_bytes": r.disk.available, "total_bytes": r.disk.total, "tiers": tiers,
                                  "safe_bytes": r.safeSelection.reduce(0) { $0 + $1.size }]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        printStatus(r)
    }

case "scan":
    let r = await scan()
    if flag("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try enc.encode(r), as: UTF8.self))
        break
    }
    for eco in Ecosystem.allCases {
        let items = r.items.filter { $0.ecosystem == eco }
        guard !items.isEmpty else { continue }
        print("\n\(eco.title.uppercased())  \(ByteFormat.string(r.total(ecosystem: eco)))")
        for i in items {
            let mark = i.isProtected ? "🔒" : "  "
            print("\(mark) \(lpad(ByteFormat.string(i.size), 9))  \(pad(i.tier.title, 11)) \(pad(i.name, 34)) \(i.protection ?? i.detail)")
        }
    }
    print("")
    printStatus(r)
    print(String(format: "Scanned in %.1f s", r.duration))

case "clean":
    guard let tierArg = value("--tier") else { fail("clean needs --tier rebuilds|redownload\n\n" + usage) }
    let tier: Tier
    switch tierArg {
    case "rebuilds": tier = .rebuilds
    case "redownload", "re-download": tier = .redownload
    case "has-data", "hasData": fail("Has-data items may hold your data. Review them one by one in the DevSweep app.")
    default: fail("Unknown tier \(tierArg)")
    }
    let r = await scan()
    let targets = r.items.filter { $0.tier == tier && !$0.isProtected }
    let skipped = r.items.filter { $0.tier == tier && $0.isProtected }
    let total = targets.reduce(0) { $0 + $1.size }
    let mode: RemovalMode = tier == .rebuilds || flag("--delete") ? .delete : .trash
    print("\(flag("--dry-run") ? "Would remove" : "Will remove") \(targets.count) items, \(ByteFormat.string(total))"
          + (mode == .trash ? " (to Trash)" : "") + (skipped.isEmpty ? "" : " · \(skipped.count) protected skipped"))
    for i in targets { print("  \(lpad(ByteFormat.string(i.size), 9))  \(i.name)  \(i.detail)") }
    for i in skipped { print("  🔒 \(i.name): \(i.protection ?? "")") }
    if flag("--dry-run") || targets.isEmpty { break }
    if !flag("--yes") {
        print("Proceed? [y/N] ", terminator: "")
        guard readLine()?.lowercased() == "y" else { print("Nothing removed."); break }
    }
    let before = DiskInfo.current().available
    let out = Cleaner().clean(targets, mode: { _ in mode })
    CleanHistory.record(out, source: "cli")
    let failed = out.filter { !$0.succeeded }
    for f in failed { print("  ✗ \(f.item.name): \(f.error ?? "")") }
    let after = DiskInfo.current().available
    let trashed = out.reduce(0) { $0 + $1.movedToTrash }
    print("✓ Done. Free space \(ByteFormat.string(before)) → \(ByteFormat.string(after))"
          + (trashed > 0 ? " · \(ByteFormat.string(trashed)) in Trash (empty it to free that space)" : ""))
    if !failed.isEmpty { exit(1) }

case "mcp":
    await MCPServer().run()

case "history":
    let entries = CleanHistory.load(limit: 30)
    if entries.isEmpty { print("No cleans recorded yet.") }
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    for e in entries {
        print("\(f.string(from: e.date))  \(pad(e.source, 16)) \(lpad(ByteFormat.string(e.freed), 9))  \(e.items.count) items"
              + (e.failures > 0 ? ", \(e.failures) skipped" : ""))
    }

default:
    print(usage)
}
