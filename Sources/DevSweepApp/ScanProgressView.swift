import DevSweepCore
import SwiftUI

/// First-scan screen: a determinate bar, a live checklist of areas, and the running total.
/// The point is to show that work is happening and what it is finding, not just that we are busy.
struct ScanProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let p = model.scanProgress
            VStack(spacing: 22) {
                LogoMark(size: 88, withPlate: true)

                VStack(spacing: 6) {
                    Text("Scanning your developer folders").font(.title2.bold())
                    Text("Read-only. Nothing is changed while scanning.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: p.fraction(now: context.date))
                        .progressViewStyle(.linear)
                        .tint(.green)
                    HStack {
                        Text("\(p.done) of \(p.steps.count) areas")
                        Spacer()
                        if let left = p.remainingText(now: context.date) { Text(left) }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .frame(width: 460)

                VStack(spacing: 2) {
                    Text(ByteFormat.string(p.foundBytes))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(value: Double(p.foundBytes)))
                        .animation(.snappy, value: p.foundBytes)
                        .monospacedDigit()
                    Text("found so far").font(.callout).foregroundStyle(.secondary)
                }

                StepGrid(progress: p)
                    .frame(maxWidth: 620)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StepGrid: View {
    let progress: ScanProgress

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
            ForEach(progress.steps) { step in
                HStack(spacing: 10) {
                    StepIcon(state: step.state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(.callout).lineLimit(1)
                        Text(detail(step)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if step.state == .done && step.bytes > 0 {
                        Text(CompactBytes.string(step.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentCard(cornerRadius: 12)
                .animation(.smooth, value: step.state)
            }
        }
    }

    private func detail(_ step: ScanStep) -> String {
        if step.id == ScanSteps.projectSearch {
            return step.state == .done ? "\(step.items) projects" : "\(progress.foldersVisited.formatted()) folders checked"
        }
        if step.state == .running { return "Measuring…" }
        return step.items == 0 ? "Nothing found" : "\(step.items) item\(step.items == 1 ? "" : "s")"
    }
}

struct StepIcon: View {
    let state: ScanStep.State

    var body: some View {
        Group {
            switch state {
            case .running:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.system(size: 16))
        .frame(width: 18)
        .accessibilityLabel(state == .done ? "Done" : "In progress")
    }
}

/// Slim strip shown on top of existing results during a rescan, so the content stays usable.
struct RescanStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let p = model.scanProgress
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.pulse, options: .repeating)
                    .foregroundStyle(.secondary)
                Text("Rescanning · \(p.done) of \(p.steps.count) areas").font(.callout)
                ProgressView(value: p.fraction(now: context.date)).tint(.green).frame(maxWidth: 220)
                if let left = p.remainingText(now: context.date) {
                    Text(left).font(.caption).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassCapsule()
            .padding(.top, 8)
        }
    }
}
