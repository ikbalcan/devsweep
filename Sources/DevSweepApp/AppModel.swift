import AppKit
import DevSweepCore
import Foundation
import Observation

enum Route: Hashable {
    case overview
    case ecosystem(Ecosystem)
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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            warnGB: 15.0,
            notificationsEnabled: true,
            showFreeInMenuBar: true,
            showInDock: true,
            lastNotifiedLevel: DiskLevel.ok.rawValue,
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


    init() {
        SettingsKey.registerDefaults()
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
        lastSummary = await run(selectedItems, modes: modes)
    }

    /// One-click clean from the menu bar or a notification: always rescans first, then removes
    /// only unprotected Rebuilds items. Protections are checked again by the Cleaner itself.
    @discardableResult
    func quickClean() async -> CleanSummary? {
        guard !isCleaning else { return nil }
        await scan()
        let targets = safeItems
        guard !targets.isEmpty else { return nil }
        let summary = await run(targets, modes: [:])
        quickSummary = summary
        return summary
    }

    private func run(_ targets: [Item], modes: [Tier: RemovalMode]) async -> CleanSummary? {
        guard !targets.isEmpty, !isCleaning else { return nil }
        isCleaning = true
        let before = DiskInfo.current().available
        let outcomes = await Task.detached(priority: .userInitiated) { () -> [CleanOutcome] in
            Cleaner().clean(targets, mode: { modes[$0] ?? $0.defaultRemovalMode }, progress: { i, item in
                Task { @MainActor in self.cleaningStatus = "\(i + 1) of \(targets.count): \(item.name)" }
            })
        }.value
        let after = DiskInfo.current().available
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
            Task { @MainActor in self?.checkDisk() }
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

    func applyDockPreference() {
        let show = UserDefaults.standard.bool(forKey: SettingsKey.showInDock)
        NSApplication.shared.setActivationPolicy(show ? .regular : .accessory)
    }

    func requestMainWindow() {
        openMainRequest += 1
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
