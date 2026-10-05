import Foundation

/// Scales wall-clock and CPU-time budgets in tests. 1 on a developer Mac; CI runners are slower
/// shared machines, so the workflow sets `WISPRLOCAL_TIMING_SCALE` (for example 2). Budgets stay
/// exact locally, and a CI run never fails just because its hardware is slower.
enum TimingBudget {
    static let scale: Double = {
        guard let raw = ProcessInfo.processInfo.environment["WISPRLOCAL_TIMING_SCALE"],
              let v = Double(raw), v >= 1 else { return 1 }
        return v
    }()
}
