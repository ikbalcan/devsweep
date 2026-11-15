import AppKit
import DevSweepCore
import SwiftUI

@main
struct DevSweepApp: App {
    @State private var model = AppModel()

    init() {
        SettingsKey.registerDefaults()
        // Lets the window come to the front when launched as a bare binary (swift run).
        let showInDock = UserDefaults.standard.bool(forKey: SettingsKey.showInDock)
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    var body: some Scene {
        Window("DevSweep", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan") { Task { await model.scan() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Rescan Fully") { Task { await model.scan(full: true) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Re-measure every folder instead of reusing sizes of unchanged ones")
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var route: Route? = .overview
    @State private var showReview = false
    @Environment(\.dismissWindow) private var dismissWindow

    private var showsSelectionBar: Bool { model.result != nil && route != .automation }

    var body: some View {
        NavigationSplitView {
            Sidebar(route: $route)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            Group {
                if let result = model.result {
                    switch route ?? .overview {
                    case .overview: OverviewView(result: result, route: $route)
                    case .ecosystem(let eco): CategoryView(ecosystem: eco)
                    case .automation: AutomationView()
                    }
                } else {
                    ScanProgressView()
                }
            }
            .overlay(alignment: .top) {
                if model.isScanning && model.result != nil {
                    RescanStrip().transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: model.isScanning)
            // Scroll content runs under the bar (extra bottom margin keeps the last row reachable),
            // so the glass has something to refract.
            .contentMargins(.bottom, showsSelectionBar ? 84 : 0, for: .scrollContent)
            .overlay(alignment: .bottom) {
                // Selection only matters where items are listed.
                if showsSelectionBar { SelectionBar(showReview: $showReview) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Scan again (⌘R)")
                    .disabled(model.isScanning || model.isCleaning)
            }
        }
        .sheet(isPresented: $showReview) { ReviewSheet() }
        .task {
            // Cached results are already on screen; refresh them once per launch, then only when stale.
            if !model.didLaunchScan {
                model.didLaunchScan = true
                await model.scan()
            } else {
                await model.scanIfStale()
            }
        }
        .onAppear {
            guard !model.launchWindowHandled else { return }
            model.launchWindowHandled = true
            if !UserDefaults.standard.bool(forKey: SettingsKey.openWindowAtLaunch) {
                dismissWindow(id: "main")
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route?

    var body: some View {
        List(selection: $route) {
            row("Overview", "gauge.with.dots.needle.33percent", model.result?.total)
                .tag(Route.overview)
            Section("Areas") {
                ForEach(Ecosystem.allCases) { eco in
                    row(eco.title, eco.symbol, model.result?.total(ecosystem: eco))
                        .tag(Route.ecosystem(eco))
                }
            }
            Section {
                row("Automation", "clock.arrow.circlepath", nil).tag(Route.automation)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ symbol: String, _ size: Int64?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let size, size > 0 {
                Text(ByteFormat.string(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showReview: Bool

    var body: some View {
        let items = model.selectedItems
        let tiers = Set(items.map(\.tier)).sorted()
        // A floating control bar over the content, not a full-width footer.
        HStack(spacing: 14) {
            if items.isEmpty {
                Text("Nothing selected").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(tiers, id: \.self) { Circle().fill($0.color).frame(width: 8, height: 8) }
                }
                Text("\(ByteFormat.string(model.selectedSize)) selected").bold().monospacedDigit()
                Text(items.count == 1 ? "1 item" : "\(items.count) items").foregroundStyle(.secondary)
            }
            Button("Review & Clean…") { showReview = true }
                .primaryGlassButton()
                .tint(.green)
                .controlSize(.large)
                .disabled(items.isEmpty || model.isScanning)
                // No Return shortcut here: Return in the bar and again in the sheet would clean without a look.
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassCapsule(tint: items.isEmpty ? nil : .green.opacity(0.22))
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }
}
