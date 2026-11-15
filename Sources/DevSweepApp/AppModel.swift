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

@MainActor
@Observable
final class AppModel {
    var result: ScanResult?
    var isScanning = false
    var selected: Set<String> = []
    var isCleaning = false
    var cleaningStatus = ""
    var lastSummary: CleanSummary?

    static let recipeTitles: [String: String] = [
        "project-artifacts": "Project build folders",
        "xcode-deriveddata": "DerivedData",
        "xcode-archives": "Archives",
        "xcode-devicesupport": "Device support",
        "simulator-devices": "Simulator devices",
        "simulator-runtimes": "Simulator runtimes",
        "android-avd": "Emulators",
        "android-sdk": "SDK packages",
        "gradle-caches": "Caches",
        "gradle-wrapper": "Gradle distributions",
        "package-caches": "Package manager caches",
    ]

    var items: [Item] { result?.items ?? [] }

    var selectedItems: [Item] { items.filter { selected.contains($0.id) && !$0.isProtected } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func items(in eco: Ecosystem) -> [Item] { items.filter { $0.ecosystem == eco } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let r = await Task.detached(priority: .userInitiated) { await Scanner().scan() }.value
        result = r
        // Default selection: only items that rebuild on their own and are not protected.
        selected = Set(r.safeSelection.map(\.id))
        isScanning = false
    }

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

    func clean(modes: [Tier: RemovalMode]) async {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        isCleaning = true
        let before = DiskInfo.current().available
        let outcomes = await Task.detached(priority: .userInitiated) { () -> [CleanOutcome] in
            Cleaner().clean(targets, mode: { modes[$0] ?? $0.defaultRemovalMode }, progress: { i, item in
                Task { @MainActor in self.cleaningStatus = "\(i + 1) of \(targets.count): \(item.name)" }
            })
        }.value
        let after = DiskInfo.current().available
        lastSummary = CleanSummary(
            freed: outcomes.reduce(0) { $0 + $1.freed },
            trashed: outcomes.reduce(0) { $0 + $1.movedToTrash },
            before: before, after: after,
            failures: outcomes.filter { !$0.succeeded }.map { ($0.item.name, $0.error ?? "") })
        isCleaning = false
        cleaningStatus = ""
        await scan()
    }
}
