import AppKit
import DevSweepCore
import SwiftUI

/// The icon in the menu bar. It is alive for the whole app lifetime, so it also starts
/// disk monitoring and opens the main window on request (it has `openWindow`).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.showFreeInMenuBar) private var showFree = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.level == .ok ? "externaldrive" : "externaldrive.badge.exclamationmark")
            if showFree || model.level != .ok {
                Text(CompactBytes.string(model.disk.available))
            }
        }
        .task { model.startMonitoring() }
        .onChange(of: model.openMainRequest) {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .accessibilityLabel("DevSweep, \(CompactBytes.string(model.disk.available)) free")
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            freeSpace
            if model.level != .ok { warning }
            action
            if let s = model.quickSummary, !model.isCleaning { resultBox(s) }
            if !model.safeItems.isEmpty && !model.isCleaning { wins }
            protectedNote
            footer
        }
        .padding(16)
        .frame(width: 340)
        .task { await model.scanIfStale() }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                LogoMark(size: 24)
                Text("DevSweep").font(.headline)
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
        }
    }

    private var freeSpace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(CompactBytes.string(model.disk.available)) free")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(model.level == .critical ? Color.red : model.level == .low ? Color.orange : Color.primary)
                Spacer()
                Text("of \(CompactBytes.string(model.disk.total))").foregroundStyle(.secondary)
            }
            if let r = model.result {
                DiskBar(result: r, height: 10)
                HStack(spacing: 12) {
                    ForEach(Tier.allCases, id: \.self) { t in
                        HStack(spacing: 5) {
                            Circle().fill(t.color).frame(width: 8, height: 8)
                            Text("\(t.title) \(CompactBytes.string(r.total(tier: t)))")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(model.level == .critical ? Color.red : Color.orange)
            Text(model.level == .critical
                 ? "Builds and simulators may fail with this little space."
                 : "Running low. Builds need room for caches and intermediates.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((model.level == .critical ? Color.red : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var action: some View {
        VStack(spacing: 6) {
            Button {
                Task { await model.quickClean() }
            } label: {
                Text(buttonTitle).frame(maxWidth: .infinity).frame(height: 28)
            }
            .primaryGlassButton()
            .tint(.green)
            .controlSize(.large)
            .disabled(model.isCleaning || model.isScanning || model.safeSize == 0)

            if model.isScanning {
                // Determinate progress with what is happening, instead of a bare spinner.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let p = model.scanProgress
                    VStack(spacing: 4) {
                        ProgressView(value: p.fraction(now: context.date)).tint(.green)
                        HStack {
                            Text("\(p.done) of \(p.steps.count) areas · \(CompactBytes.string(p.foundBytes)) found")
                            Spacer()
                            if let left = p.remainingText(now: context.date) { Text(left) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            } else {
                Text(model.isCleaning ? model.cleaningStatus
                     : "Only items that rebuild on their own · active projects skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var buttonTitle: String {
        if model.isCleaning { return "Cleaning…" }
        if model.isScanning { return model.result == nil ? "Scanning…" : "Checking…" }
        if model.safeSize == 0 { return "Nothing safe to free" }
        return "Free \(CompactBytes.string(model.safeSize)) safely"
    }

    private func resultBox(_ s: CleanSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(s.failures.isEmpty ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Freed \(CompactBytes.string(s.freed)) · now \(CompactBytes.string(s.after)) free").font(.callout.bold())
                if !s.failures.isEmpty {
                    Text("\(s.failures.count) item(s) skipped. See details in the main window.").font(.caption)
                }
            }
            Spacer()
            Button { model.quickSummary = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var wins: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BIGGEST SAFE WINS").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(model.safeItems.sorted { $0.size > $1.size }.prefix(4)) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text(CompactBytes.string(item.size)).monospacedDigit().fontWeight(.semibold)
                }
                .font(.callout)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private var protectedNote: some View {
        // Devices first: "iPhone 17 is running" is what people recognise.
        let inUse = model.items
            .filter { ($0.protection ?? "").localizedCaseInsensitiveContains("running") }
            .sorted { a, b in
                let da = a.recipeID == "simulator-devices" || a.recipeID == "android-avd"
                let db = b.recipeID == "simulator-devices" || b.recipeID == "android-avd"
                return da != db ? da : a.size > b.size
            }
        if !inUse.isEmpty {
            let names = inUse.prefix(2).map(\.name).joined(separator: ", ")
            Label("Kept while in use: \(names)" + (inUse.count > 2 ? " +\(inUse.count - 2)" : ""),
                  systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack {
            if let r = model.result {
                Text("Scanned \(RelativeDate.string(r.scannedAt))").font(.caption).foregroundStyle(.secondary)
                Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.isScanning || model.isCleaning)
                    .help("Scan again")
                    .accessibilityLabel("Scan again")
            }
            Spacer()
            Button("Open DevSweep") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.link)
        }
    }
}
