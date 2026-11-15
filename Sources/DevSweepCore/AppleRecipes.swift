import Foundation

private let xcrun = "/usr/bin/xcrun"

struct DerivedDataRecipe: Recipe {
    let id = "xcode-deriveddata"

    func discover(_ ctx: ScanContext) async -> [Item] {
        let root = ctx.home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let dirs = FileManager.default.subdirectories(of: root)
        let sizes = await FileSize.measure(dirs)
        return dirs.map { dir in
            let name = dir.lastPathComponent
            let workspace = Self.workspacePath(dir)
            let modified = FileManager.default.modificationDate(dir.appendingPathComponent("Logs"))
                ?? FileManager.default.modificationDate(dir)
            var protection: String?
            if ctx.snapshot.xcodeRunning, let m = modified, ctx.now.timeIntervalSince(m) < 2 * 86_400 {
                protection = "Xcode is open and used this recently"
            }
            var detail = "Build products and index"
            if let ws = workspace {
                detail = FileManager.default.fileExists(atPath: ws)
                    ? PathDisplay.tilde(URL(fileURLWithPath: ws))
                    : "Project no longer exists: \(PathDisplay.tilde(URL(fileURLWithPath: ws)))"
            } else if name.hasSuffix(".noindex") {
                detail = "Shared module and compilation cache"
            }
            return Item(recipeID: id, key: name, ecosystem: .xcode, tier: .rebuilds,
                        name: Self.displayName(name), detail: detail, paths: [dir], size: sizes[dir] ?? 0,
                        lossNote: "The next Xcode build of this project is a clean build and re-indexes once.",
                        protection: protection, lastUsed: modified)
        }
    }

    /// "Runner-cvhfebcvlxujzzebrdqomjgnkbao" -> "Runner"
    static func displayName(_ folder: String) -> String {
        if folder.hasSuffix(".noindex") { return String(folder.dropLast(8)) }
        guard let dash = folder.lastIndex(of: "-") else { return folder }
        let suffix = folder[folder.index(after: dash)...]
        return suffix.count == 28 && suffix.allSatisfy({ $0.isLetter }) ? String(folder[..<dash]) : folder
    }

    static func workspacePath(_ dir: URL) -> String? {
        let plist = dir.appendingPathComponent("info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return obj["WorkspacePath"] as? String
    }
}

struct ArchivesRecipe: Recipe {
    let id = "xcode-archives"

    func discover(_ ctx: ScanContext) async -> [Item] {
        let root = ctx.home.appendingPathComponent("Library/Developer/Xcode/Archives")
        let fm = FileManager.default
        var archives: [URL] = []
        for day in fm.subdirectories(of: root) {
            let entries = (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []
            archives += entries.filter { $0.pathExtension == "xcarchive" }
        }
        let sizes = await FileSize.measure(archives)
        return archives.map { a in
            let info = Self.info(a)
            let created = info.date ?? fm.modificationDate(a)
            var protection: String?
            if let c = created, ctx.now.timeIntervalSince(c) < Double(ctx.options.archiveKeepDays) * 86_400 {
                protection = "Newer than \(ctx.options.archiveKeepDays) days"
            }
            let version = [info.version, info.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            return Item(recipeID: id, key: a.path, ecosystem: .xcode, tier: .hasData,
                        name: info.name ?? a.deletingPathExtension().lastPathComponent,
                        detail: [version, RelativeDate.string(created, now: ctx.now)].filter { !$0.isEmpty }.joined(separator: " · "),
                        paths: [a], size: sizes[a] ?? 0,
                        lossNote: "The signed build and its dSYMs. Without dSYMs, crash reports from this version can no longer be symbolicated.",
                        protection: protection, lastUsed: created)
        }
    }

    static func info(_ archive: URL) -> (name: String?, version: String?, build: String?, date: Date?) {
        guard let data = try? Data(contentsOf: archive.appendingPathComponent("Info.plist")),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil, nil, nil) }
        let props = obj["ApplicationProperties"] as? [String: Any]
        return (obj["Name"] as? String, props?["CFBundleShortVersionString"] as? String,
                props?["CFBundleVersion"] as? String, obj["CreationDate"] as? Date)
    }
}

struct DeviceSupportRecipe: Recipe {
    let id = "xcode-devicesupport"

    func discover(_ ctx: ScanContext) async -> [Item] {
        let base = ctx.home.appendingPathComponent("Library/Developer/Xcode")
        let fm = FileManager.default
        let platforms = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasSuffix("DeviceSupport") }
        var items: [Item] = []
        for platform in platforms {
            let dirs = fm.subdirectories(of: base.appendingPathComponent(platform))
            let sizes = await FileSize.measure(dirs)
            // Keep the most recently used one per platform: that is the device you are likely still using.
            let newest = dirs.max { (fm.modificationDate($0) ?? .distantPast) < (fm.modificationDate($1) ?? .distantPast) }
            for d in dirs {
                items.append(Item(recipeID: id, key: d.path, ecosystem: .xcode, tier: .redownload,
                                  name: "\(platform.replacingOccurrences(of: " DeviceSupport", with: "")) \(d.lastPathComponent)",
                                  detail: "Debug symbols copied from a connected device",
                                  paths: [d], size: sizes[d] ?? 0,
                                  lossNote: "Copied again (slowly) the next time you connect a device running this OS version.",
                                  protection: d == newest ? "Most recently used device version" : nil,
                                  lastUsed: fm.modificationDate(d)))
            }
        }
        return items
    }
}

struct SimulatorDevicesRecipe: Recipe {
    let id = "simulator-devices"

    struct DeviceList: Decodable { let devices: [String: [Device]] }
    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let dataPath: String?
        let dataPathSize: Int64?
        let logPathSize: Int64?
        let lastBootedAt: String?
        let availabilityError: String?
    }

    func discover(_ ctx: ScanContext) async -> [Item] {
        let r = Shell.run(xcrun, ["simctl", "list", "devices", "-j"], timeout: 60)
        guard r.ok, let list = try? JSONDecoder().decode(DeviceList.self, from: Data(r.stdout.utf8)) else { return [] }
        let iso = ISO8601DateFormatter()
        var items: [Item] = []
        for (runtime, devices) in list.devices {
            let os = Self.runtimeName(runtime)
            for d in devices {
                let deviceDir = d.dataPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                var size = (d.dataPathSize ?? 0) + (d.logPathSize ?? 0)
                if size == 0, let dir = deviceDir { size = FileSize.allocated(dir) }
                let available = d.isAvailable ?? true
                let booted = d.state == "Booted"
                let last = d.lastBootedAt.flatMap { iso.date(from: $0) }
                var detail = "\(os) · " + (booted ? "Running" : "Last booted \(RelativeDate.string(last, now: ctx.now))")
                if !available { detail = "\(os) · Unavailable (runtime removed)" }
                items.append(Item(recipeID: id, key: d.udid, ecosystem: .simulators, tier: .hasData,
                                  name: d.name, detail: detail, paths: deviceDir.map { [$0] } ?? [], size: size,
                                  action: .command([xcrun, "simctl", "delete", d.udid]),
                                  lossNote: available
                                    ? "Installed apps, their data, keychain and settings on this simulator. You can recreate the device in Xcode in seconds."
                                    : "Nothing usable: this device cannot boot because its runtime is gone.",
                                  protection: booted ? "Simulator is running" : nil, lastUsed: last))
            }
        }
        return items
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-2" -> "iOS 26.2"
    static func runtimeName(_ id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        return "\(platform) " + parts.dropFirst().joined(separator: ".")
    }
}

struct SimulatorRuntimesRecipe: Recipe {
    let id = "simulator-runtimes"

    struct Runtime: Decodable {
        let identifier: String
        let version: String?
        let build: String?
        let deletable: Bool?
        let sizeBytes: Int64?
        let runtimeIdentifier: String?
        let lastUsedAt: String?
        let platformIdentifier: String?
    }

    func discover(_ ctx: ScanContext) async -> [Item] {
        let r = Shell.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 60)
        guard r.ok, let map = try? JSONDecoder().decode([String: Runtime].self, from: Data(r.stdout.utf8)) else { return [] }
        let devicesJSON = Shell.run(xcrun, ["simctl", "list", "devices", "-j"], timeout: 60)
        let deviceList = try? JSONDecoder().decode(SimulatorDevicesRecipe.DeviceList.self, from: Data(devicesJSON.stdout.utf8))
        let iso = ISO8601DateFormatter()
        return map.values.map { rt in
            let devices = deviceList?.devices[rt.runtimeIdentifier ?? ""] ?? []
            let booted = devices.contains { $0.state == "Booted" }
            let platform = rt.platformIdentifier?.contains("iphone") == true ? "iOS"
                : SimulatorDevicesRecipe.runtimeName(rt.runtimeIdentifier ?? "").split(separator: " ").first.map(String.init) ?? "Runtime"
            var protection: String?
            if rt.deletable == false { protection = "Managed by the system" }
            else if booted { protection = "A simulator on this runtime is running" }
            let last = rt.lastUsedAt.flatMap { iso.date(from: $0) }
            return Item(recipeID: id, key: rt.identifier, ecosystem: .simulators, tier: .redownload,
                        name: "\(platform) \(rt.version ?? "") runtime", detail: "\(devices.count) device(s) · build \(rt.build ?? "?")",
                        paths: [], size: rt.sizeBytes ?? 0,
                        action: .command([xcrun, "simctl", "runtime", "delete", rt.identifier]),
                        lossNote: "Re-downloaded from Xcode > Settings > Components when needed (several GB). Its \(devices.count) simulator(s) become unavailable.",
                        protection: protection, lastUsed: last)
        }
    }
}
