import AppKit
import DevSweepCore
import SwiftUI

@main
struct DevSweepApp: App {
    @State private var model = AppModel()

    init() {
        // Lets the window come to the front when launched as a bare binary (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("DevSweep") {
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
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var route: Route? = .overview
    @State private var showReview = false

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
                    }
                } else {
                    ScanningPlaceholder()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.result != nil { SelectionBar(showReview: $showReview) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                        .help("Scan again (⌘R)")
                }
            }
        }
        .sheet(isPresented: $showReview) { ReviewSheet() }
        .task { if model.result == nil { await model.scan() } }
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

struct ScanningPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning developer folders…").font(.headline)
            Text("Xcode, simulators, Android, Gradle, projects and package caches. Nothing is changed.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showReview: Bool

    var body: some View {
        let items = model.selectedItems
        let tiers = Set(items.map(\.tier)).sorted()
        HStack {
            if items.isEmpty {
                Text("Nothing selected").foregroundStyle(.secondary)
            } else {
                Text("\(ByteFormat.string(model.selectedSize)) selected").bold()
                Text("· \(items.count) items · \(tiers.map(\.title).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review & Clean…") { showReview = true }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(items.isEmpty || model.isScanning)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
