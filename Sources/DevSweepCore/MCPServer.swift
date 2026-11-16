import Foundation

/// A small Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
///
/// Agents get three tools. `disk_status` answers from the live disk and the cached last scan,
/// `plan_cleanup` is read-only, and `clean_safe` can only ever remove unprotected **Rebuilds**
/// items, after a fresh scan, and only while "Allow agents to clean" is on in DevSweep.
public final class MCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let scan: () async -> ScanResult
    let clean: ([Item]) -> [CleanOutcome]
    let cacheURL: URL
    let historyURL: URL
    let allowClean: () -> Bool
    let version: String

    public init(version: String = DevSweepVersion.current,
                scan: @escaping () async -> ScanResult = { await Scanner().scan() },
                clean: @escaping ([Item]) -> [CleanOutcome] = { Cleaner().clean($0, mode: { $0.defaultRemovalMode }) },
                cacheURL: URL = ScanCache.url, historyURL: URL = CleanHistory.url,
                allowClean: @escaping () -> Bool = { SharedSettings.allowAgentClean }) {
        self.version = version
        self.scan = scan
        self.clean = clean
        self.cacheURL = cacheURL
        self.historyURL = historyURL
        self.allowClean = allowClean
    }

    /// Reads requests from stdin until EOF and writes responses to stdout.
    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    /// Handles one JSON-RPC message. Returns the response line, or nil for notifications.
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let method = msg["method"] as? String ?? ""
        guard let id = msg["id"] else { return nil }  // notification, e.g. notifications/initialized
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "devsweep", "version": self.version],
                "instructions": "DevSweep frees disk space on a developer Mac safely. Call disk_status first. Call plan_cleanup to see what would be removed. clean_safe only removes build output and caches that regenerate on their own; it never touches source code, simulators, emulators or anything that may hold user data.",
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (payload, isError) = await callTool(name, args)
            let text = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    static let tools: [[String: Any]] = [
        [
            "name": "disk_status",
            "description": "Free disk space and, from the last DevSweep scan, how much can be freed safely. Fast: does not scan.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "plan_cleanup",
            "description": "List what DevSweep would remove for a tier, and what it keeps protected (running simulators, active projects, in-use versions). Read-only. Scans when the cached scan is older than max_age_minutes (a scan takes about a minute).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tier": ["type": "string", "enum": ["rebuilds", "redownload"], "default": "rebuilds",
                             "description": "rebuilds: regenerates on next build. redownload: no data loss but needs internet again."],
                    "max_age_minutes": ["type": "integer", "default": 30, "minimum": 0],
                ],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "clean_safe",
            "description": "Free disk space by removing only unprotected Rebuilds items: build folders of inactive projects and caches that regenerate on their own. Always scans first. Never removes source code, simulators, emulators, archives or app data. Can be turned off by the user in DevSweep.",
            "inputSchema": [
                "type": "object",
                "properties": ["dry_run": ["type": "boolean", "default": false,
                                           "description": "Only report what would be removed."]],
            ],
            "annotations": ["destructiveHint": true, "idempotentHint": true],
        ],
    ]

    func callTool(_ name: String, _ args: [String: Any]) async -> ([String: Any], Bool) {
        switch name {
        case "disk_status":
            return (diskStatus(), false)
        case "plan_cleanup":
            let tierName = args["tier"] as? String ?? "rebuilds"
            guard let tier = Self.tier(tierName) else { return (["error": "Unknown tier \(tierName)"], true) }
            let maxAge = (args["max_age_minutes"] as? NSNumber)?.doubleValue ?? 30
            let result = await scanIfNeeded(maxAgeMinutes: maxAge)
            return (plan(result, tier: tier), false)
        case "clean_safe":
            let dryRun = args["dry_run"] as? Bool ?? false
            if !dryRun && !allowClean() {
                return (["error": "Cleaning by agents is turned off in DevSweep (Automation > Allow agents to clean). Ask the user to clean from the DevSweep app."], true)
            }
            let result = await freshScan()
            let targets = result.safeSelection
            if dryRun || targets.isEmpty {
                var p = plan(result, tier: .rebuilds)
                p["dry_run"] = dryRun
                return (p, false)
            }
            let before = DiskInfo.current().available
            let outcomes = clean(targets)
            CleanHistory.record(outcomes, source: "mcp", to: historyURL)
            let after = DiskInfo.current().available
            let failed = outcomes.filter { !$0.succeeded }
            return ([
                "freed_bytes": outcomes.reduce(0) { $0 + $1.freed },
                "freed": ByteFormat.string(outcomes.reduce(0) { $0 + $1.freed }),
                "free_before": ByteFormat.string(before),
                "free_after": ByteFormat.string(after),
                "removed": outcomes.filter(\.succeeded).map(\.item.name),
                "skipped": failed.map { ["name": $0.item.name, "reason": $0.error ?? ""] },
            ], false)
        default:
            return (["error": "Unknown tool \(name)"], true)
        }
    }

    static func tier(_ s: String) -> Tier? {
        switch s {
        case "rebuilds": return .rebuilds
        case "redownload", "re-download": return .redownload
        default: return nil
        }
    }

    func diskStatus() -> [String: Any] {
        let disk = DiskInfo.current()
        let level = LowDiskPolicy().level(disk.available)
        var out: [String: Any] = [
            "free_bytes": disk.available, "free": ByteFormat.string(disk.available),
            "total": ByteFormat.string(disk.total),
            "level": level == .ok ? "ok" : level == .low ? "low" : "critical",
        ]
        if let cached = ScanCache.load(from: cacheURL) {
            out["last_scan_minutes_ago"] = Int(Date().timeIntervalSince(cached.scannedAt) / 60)
            out["safe_to_free"] = ByteFormat.string(cached.safeSelection.reduce(0) { $0 + $1.size })
            out["tiers"] = Dictionary(uniqueKeysWithValues: Tier.allCases.map { ($0.rawValue, ByteFormat.string(cached.total(tier: $0))) })
        } else {
            out["note"] = "No scan yet. Call plan_cleanup to scan (about a minute)."
        }
        return out
    }

    func plan(_ r: ScanResult, tier: Tier) -> [String: Any] {
        let items = r.items.filter { $0.tier == tier }
        let targets = items.filter { !$0.isProtected }
        let kept = items.filter(\.isProtected)
        return [
            "tier": tier.rawValue,
            "scanned_minutes_ago": Int(Date().timeIntervalSince(r.scannedAt) / 60),
            "would_free": ByteFormat.string(targets.reduce(0) { $0 + $1.size }),
            "items": targets.map { ["name": $0.name, "size": ByteFormat.string($0.size), "detail": $0.detail,
                                    "what_happens": $0.lossNote] },
            "protected": kept.map { ["name": $0.name, "size": ByteFormat.string($0.size), "reason": $0.protection ?? ""] },
            "free_now": ByteFormat.string(r.disk.available),
        ]
    }

    func scanIfNeeded(maxAgeMinutes: Double) async -> ScanResult {
        if let cached = ScanCache.load(from: cacheURL), Date().timeIntervalSince(cached.scannedAt) < maxAgeMinutes * 60 {
            return cached
        }
        return await freshScan()
    }

    func freshScan() async -> ScanResult {
        let r = await scan()
        ScanCache.save(r, to: cacheURL)
        return r
    }

    private func reply(_ id: Any, _ result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}
