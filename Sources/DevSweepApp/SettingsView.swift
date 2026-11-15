import DevSweepCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.warnGB) private var warnGB = 15.0
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(SettingsKey.showFreeInMenuBar) private var showFree = true
    @AppStorage(SettingsKey.showInDock) private var showInDock = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section("Low disk warning") {
                Picker("Warn when free space drops below", selection: $warnGB) {
                    ForEach([5.0, 10.0, 15.0, 20.0, 30.0, 50.0], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                }
                Toggle("Show a notification", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, on in
                        if on { Task { _ = await Notifier.shared.requestAuthorization(); await refreshStatus() } }
                    }
                if notificationsEnabled && notificationStatus == .denied {
                    Text("Notifications are turned off for DevSweep in System Settings > Notifications.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !Notifier.shared.isAvailable {
                    Text("Notifications only work when DevSweep runs as an app (scripts/bundle.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("You get one notification when space drops below this, and another below 5 GB. It does not repeat until space recovers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar and Dock") {
                Toggle("Show free space next to the menu bar icon", isOn: $showFree)
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { model.applyDockPreference() }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onChange(of: warnGB) {
            // A new threshold starts fresh: the next check decides again whether to warn.
            UserDefaults.standard.set(DiskLevel.ok.rawValue, forKey: SettingsKey.lastNotifiedLevel)
            model.checkDisk()
        }
        .task { await refreshStatus() }
    }

    private func refreshStatus() async {
        notificationStatus = await Notifier.shared.authorizationStatus()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
