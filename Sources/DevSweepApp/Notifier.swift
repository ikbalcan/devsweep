import AppKit
import DevSweepCore
import os
import UserNotifications

let log = Logger(subsystem: "dev.devsweep.app", category: "notifications")

/// Low-disk and clean-result notifications. Only active inside a real .app bundle:
/// UNUserNotificationCenter needs a bundle identifier and crashes in a bare `swift run` binary.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static let lowDiskCategory = "LOW_DISK"
    static let freeSafeAction = "FREE_SAFE"

    private weak var model: AppModel?
    private var configured = false

    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func setUp(model: AppModel) {
        self.model = model
        guard isAvailable, !configured else { return }
        configured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled) {
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                log.notice("authorization granted=\(granted, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func postLowDisk(level: DiskLevel, available: Int64, safeBytes: Int64) {
        guard isAvailable, level != .ok else { return }
        let center = UNUserNotificationCenter.current()
        // The action title carries the number, so the category is refreshed for each post.
        var actions: [UNNotificationAction] = []
        if safeBytes > 0 {
            actions.append(UNNotificationAction(identifier: Self.freeSafeAction,
                                                title: "Free \(CompactBytes.string(safeBytes)) safely", options: []))
        }
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.lowDiskCategory, actions: actions,
                                                                 intentIdentifiers: [], options: [])])
        let content = UNMutableNotificationContent()
        content.title = level == .critical
            ? "Disk almost full · \(CompactBytes.string(available)) left"
            : "Low disk space · \(CompactBytes.string(available)) left"
        content.body = safeBytes > 0
            ? "\(CompactBytes.string(safeBytes)) can be freed with no data loss. Only build output and caches that rebuild on their own."
            : "Open DevSweep to see what can be cleaned."
        content.categoryIdentifier = Self.lowDiskCategory
        content.sound = level == .critical ? .default : nil
        center.add(UNNotificationRequest(identifier: "low-disk", content: content, trigger: nil)) { error in
            log.notice("low-disk posted level=\(level.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func postCleanResult(_ s: CleanSummary) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = s.failures.isEmpty
            ? "Freed \(CompactBytes.string(s.freed))"
            : "Freed \(CompactBytes.string(s.freed)), \(s.failures.count) item(s) skipped"
        content.body = "Free space \(CompactBytes.string(s.before)) → \(CompactBytes.string(s.after))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "clean-result", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            guard let model = self.model else { return }
            if category == Self.lowDiskCategory && action == Self.freeSafeAction {
                if let summary = await model.quickClean() { self.postCleanResult(summary) }
            } else if action == UNNotificationDefaultActionIdentifier {
                model.requestMainWindow()
            }
        }
        completionHandler()
    }
}
