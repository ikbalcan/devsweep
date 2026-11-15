import AppKit
import DevSweepCore
import Foundation
import Observation

enum Route: Hashable {
    case overview
    case ecosystem(Ecosystem)
    case automation
}

struct CleanSummary {
    let freed: Int64
    let trashed: Int64
    let before: Int64
    let after: Int64
    let failures: [(name: String, error: String)]
}

enum SettingsKey {
    static let warnGB = "warnGB"
    static let notificationsEnabled = "notificationsEnabled"
    static let showFreeInMenuBar = "showFreeInMenuBar"
    static let showInDock = "showInDock"
    static let lastNotifiedLevel = "lastNotifiedLevel"
    static let openWindowAtLaunch = "openWindowAtLaunch"
    static let ruleWeeklySweep = "ruleWeeklySweep"
    static let ruleAutoCleanCritical = "ruleAutoCleanCritical"
    static let ruleRemoveUnavailableSims = "ruleRemoveUnavailableSims"
    static let lastWeeklySweep = "lastWeeklySweep"
    static let lastAutoClean = "lastAutoClean"
    static let lastSimCleanup = "lastSimCleanup"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            warnGB: 15.0,
            notificationsEnabled: true,
            showFreeInMenuBar: true,
            showInDock: true,
            lastNotifiedLevel: DiskLevel.ok.rawValue,
            openWindowAtLaunch: true,
            // Rules that remove things on their own start off; the user turns them on.
            ruleWeeklySweep: false,
            ruleAutoCleanCritical: false,
            ruleRemoveUnavailableSims: false,
        ])
    }
}

@MainActor
@Observable
final class AppModel {
    var result: ScanResult?
    var isScanning = false
    var selected: Set<String> = []
    var isCleaning = false
    var cleaningStatus = ""
    var lastSummary: CleanSummary?
    /// Result of the last one-click clean, shown in the menu bar popover.
    var quickSummary: CleanSummary?
    /// Live free space, refreshed every minute. Cheap: no scan involved.
    var disk = DiskInfo.current()
    /// Bumped to ask a view that has `openWindow` to show the main window.
    var openMainRequest = 0
    /// Live state of the running scan, for the progress UI.
    var scanProgress = ScanProgress(startedAt: Date(), expectedDuration: 0)

    private var monitorTimer: Timer?
    /// A scan older than this is refreshed before acting on it.
    static let staleAfter: TimeInterval = 30 * 60


    /// Recent cleans from every source, for the Automation screen.
    var history: [CleanHistory.Entry] = []
    /// The window should close itself once if the user asked to start in the menu bar only.
    var launchWindowHandled = false
    var didLaunchScan = false

    init() {
        SettingsKey.registerDefaults()
        // Open with the last scan right away; a fresh scan runs in the background.
        if let cached = ScanCache.load() {
            result = cached
            disk = DiskInfo.current()
            selected = Set(cached.safeSelection.map(\.id))
        }
        history = CleanHistory.load(limit: 30)
    }

    // MARK: Settings

    var policy: LowDiskPolicy {
        let warn = max(UserDefaults.standard.double(forKey: SettingsKey.warnGB), 1)
        return LowDiskPolicy(warnBytes: Int64(warn * 1_000_000_000))
    }

    var level: DiskLevel { policy.level(disk.available) }

    // MARK: Derived

    var items: [Item] { result?.items ?? [] }
    var selectedItems: [Item] { items.filter { selected.contains($0.id) && !$0.isProtected } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var safeItems: [Item] { result?.safeSelection ?? [] }
    var safeSize: Int64 { safeItems.reduce(0) { $0 + $1.size } }
    var isStale: Bool { result.map { Date().timeIntervalSince($0.scannedAt) > Self.staleAfter } ?? true }

    func items(in eco: Ecosystem) -> [Item] { items.filter { $0.ecosystem == eco } }

    // MARK: Scanning

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = ScanProgress(startedAt: Date(),
                                    expectedDuration: UserDefaults.standard.double(forKey: "lastScanDuration"))
        let r = await Task.detached(priority: .userInitiated) {
            await Scanner().scan { event in
                Task { @MainActor [weak self] in self?.scanProgress.apply(event) }
            }
        }.value
        result = r
        disk = r.disk
        ScanCache.save(r)
        // A scan that sat behind a macOS permission prompt is not a useful estimate for the next one.
        if r.duration < 300 { UserDefaults.standard.set(r.duration, forKey: "lastScanDuration") }
        // Default selection: only items that rebuild on their own and are not protected.
        selected = Set(r.safeSelection.map(\.id))
        isScanning = false
    }

    func scanIfStale() async {
        if isStale && !isScanning && !isCleaning { await scan() }
    }

    // MARK: Selection

    func isSelected(_ item: Item) -> Bool { selected.contains(item.id) }

    func setSelected(_ item: Item, _ on: Bool) {
        guard !item.isProtected else { return }
        if on { selected.insert(item.id) } else { selected.remove(item.id) }
    }

    func selectAllSafe(in eco: Ecosystem) {
        for i in items(in: eco) where i.tier == .rebuilds && !i.isProtected { selected.insert(i.id) }
    }

    func clearSelection(in eco: Ecosystem) {
        for i in items(in: eco) { selected.remove(i.id) }
    }

    // MARK: Cleaning

    /// Cleans what the user selected in the main window, with the modes chosen in the review sheet.
    func clean(modes: [Tier: RemovalMode]) async {
        lastSummary = await run(selectedItems, modes: modes, source: "app")
    }

    /// One-click clean from the menu bar or a notification: always rescans first, then removes
    /// only unprotected Rebuilds items. Protections are checked again by the Cleaner itself.
    @discardableResult
    func quickClean(source: String = "menu bar") async -> CleanSummary? {
        guard !isCleaning else { return nil }
        await scan()
        let targets = safeItems
        guard !targets.isEmpty else { return nil }
        let summary = await run(targets, modes: [:], source: source)
        quickSummary = summary
        return summary
    }

    private func run(_ targets: [Item], modes: [Tier: RemovalMode], source: String) async -> CleanSummary? {
        guard !targets.isEmpty, !isCleaning else { return nil }
        isCleaning = true
        let before = DiskInfo.current().available
        let outcomes = await Task.detached(priority: .userInitiated) { () -> [CleanOutcome] in
            Cleaner().clean(targets, mode: { modes[$0] ?? $0.defaultRemovalMode }, progress: { i, item in
                Task { @MainActor in self.cleaningStatus = "\(i + 1) of \(targets.count): \(item.name)" }
            })
        }.value
        let after = DiskInfo.current().available
        CleanHistory.record(outcomes, source: source)
        history = CleanHistory.load(limit: 30)
        let summary = CleanSummary(
            freed: outcomes.reduce(0) { $0 + $1.freed },
            trashed: outcomes.reduce(0) { $0 + $1.movedToTrash },
            before: before, after: after,
            failures: outcomes.filter { !$0.succeeded }.map { ($0.item.name, $0.error ?? "") })
        isCleaning = false
        cleaningStatus = ""
        await scan()
        return summary
    }

    // MARK: Monitoring

    func startMonitoring() {
        guard monitorTimer == nil else { return }
        Notifier.shared.setUp(model: self)
        applyDockPreference()
        checkDisk()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDisk()
                await self?.runRules()
            }
        }
    }

    func checkDisk() {
        disk = DiskInfo.current()
        let defaults = UserDefaults.standard
        let last = DiskLevel(rawValue: defaults.integer(forKey: SettingsKey.lastNotifiedLevel)) ?? .ok
        let decision = policy.evaluate(available: disk.available, lastNotified: last)
        defaults.set(decision.lastNotified.rawValue, forKey: SettingsKey.lastNotifiedLevel)
        guard let notifyLevel = decision.notify, defaults.bool(forKey: SettingsKey.notificationsEnabled) else { return }
        Task {
            // Make the "can be freed" number trustworthy before showing it.
            while isScanning { try? await Task.sleep(for: .seconds(1)) }
            await scanIfStale()
            Notifier.shared.postLowDisk(level: notifyLevel, available: disk.available, safeBytes: safeSize)
        }
    }

    // MARK: Always keep

    func isKept(_ item: Item) -> Bool { SharedSettings.keepList.contains(item.id) }

    func setKept(_ item: Item, _ keep: Bool) {
        var list = SharedSettings.keepList
        if keep { list.insert(item.id) } else { list.remove(item.id) }
        SharedSettings.keepList = list
        guard var r = result, let i = r.items.firstIndex(where: { $0.id == item.id }) else { return }
        var items = r.items
        if keep && items[i].protection == nil {
            items[i].protection = "You chose to always keep this"
            selected.remove(item.id)
        } else if !keep && items[i].protection == "You chose to always keep this" {
            items[i].protection = nil
        }
        r = ScanResult(items: items, disk: r.disk, scannedAt: r.scannedAt, duration: r.duration)
        result = r
    }

    // MARK: Automation rules

    private var isRunningRule = false

    /// Called every minute. Each rule is off by default and rate-limited.
    func runRules(now: Date = Date()) async {
        guard !isRunningRule, !isScanning, !isCleaning else { return }
        isRunningRule = true
        defer { isRunningRule = false }
        let d = UserDefaults.standard

        if d.bool(forKey: SettingsKey.ruleAutoCleanCritical), level == .critical,
           now.timeIntervalSince(d.object(forKey: SettingsKey.lastAutoClean) as? Date ?? .distantPast) > 3600 {
            d.set(now, forKey: SettingsKey.lastAutoClean)
            if let s = await quickClean(source: "rule: low disk") {
                Notifier.shared.postCleanResult(s, title: "Disk was almost full")
            }
        }

        if d.bool(forKey: SettingsKey.ruleWeeklySweep),
           now.timeIntervalSince(d.object(forKey: SettingsKey.lastWeeklySweep) as? Date ?? .distantPast) > 7 * 86_400 {
            d.set(now, forKey: SettingsKey.lastWeeklySweep)
            await scan()
            let cutoff = now.addingTimeInterval(-30 * 86_400)
            let stale = items.filter { $0.ecosystem == .projects && $0.tier == .rebuilds && !$0.isProtected
                && ($0.lastUsed.map { $0 < cutoff } ?? false) }
            if let s = await run(stale, modes: [:], source: "rule: weekly sweep"), s.freed > 0 {
                Notifier.shared.postCleanResult(s, title: "Weekly sweep of stale projects")
            }
        }

        if d.bool(forKey: SettingsKey.ruleRemoveUnavailableSims),
           now.timeIntervalSince(d.object(forKey: SettingsKey.lastSimCleanup) as? Date ?? .distantPast) > 86_400 {
            d.set(now, forKey: SettingsKey.lastSimCleanup)
            let unavailable = items.filter { $0.recipeID == "simulator-devices" && $0.detail.contains("Unavailable") && !$0.isProtected }
            if !unavailable.isEmpty {
                _ = await run(unavailable, modes: [:], source: "rule: unavailable simulators")
            }
        }
    }

    func applyDockPreference() {
        let show = UserDefaults.standard.bool(forKey: SettingsKey.showInDock)
        NSApplication.shared.setActivationPolicy(show ? .regular : .accessory)
    }

    func requestMainWindow() {
        openMainRequest += 1
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
