import DevSweepCore
import Foundation

struct ScanStep: Identifiable, Equatable {
    enum State: Equatable { case running, done }
    let id: String
    var state: State = .running
    var items = 0
    var bytes: Int64 = 0

    var title: String { ScanSteps.title(id) }
}

/// What the progress UI shows while a scan runs.
struct ScanProgress {
    let startedAt: Date
    /// Duration of the previous scan, used for an honest "about N s left". 0 when unknown.
    let expectedDuration: TimeInterval
    var steps: [ScanStep] = []
    var foldersVisited = 0

    var done: Int { steps.filter { $0.state == .done }.count }
    var total: Int { max(steps.count, 1) }
    var foundBytes: Int64 { steps.reduce(0) { $0 + $1.bytes } }

    /// Blend of finished steps and elapsed time, so the bar keeps moving during the long project search.
    func fraction(now: Date = Date()) -> Double {
        let stepFraction = Double(done) / Double(total)
        guard expectedDuration > 0 else { return stepFraction }
        let timeFraction = min(now.timeIntervalSince(startedAt) / expectedDuration, 0.95)
        return min(max(stepFraction, timeFraction * 0.6 + stepFraction * 0.4), done == total ? 1 : 0.98)
    }

    func remainingText(now: Date = Date()) -> String? {
        guard expectedDuration > 0 else { return nil }
        let left = expectedDuration - now.timeIntervalSince(startedAt)
        if left <= 3 { return "Almost done" }
        if left < 60 { return "About \(Int(left.rounded())) s left" }
        return "About \(Int((left / 60).rounded())) min left"
    }

    mutating func apply(_ event: ScanEvent) {
        switch event {
        case .started(let ids):
            steps = ids.map { ScanStep(id: $0) }
        case .projectSearch(let visited):
            foldersVisited = visited
        case .stepFinished(let id, let items, let bytes):
            if let i = steps.firstIndex(where: { $0.id == id }) {
                steps[i].state = .done
                steps[i].items = items
                steps[i].bytes = bytes
            }
        }
    }
}
