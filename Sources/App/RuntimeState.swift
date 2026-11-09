import Observation

/// The one place that decides whether tracking and rendering run (plan §3).
@MainActor
@Observable
final class RuntimeState {
    /// A video app is showing vutusi Camera.
    var isSourceRunning = false { didSet { notifyIfChanged() } }

    var isActive: Bool { isSourceRunning }

    /// Called with the new `isActive` whenever it flips.
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    @ObservationIgnored private var lastActive = false

    private func notifyIfChanged() {
        guard isActive != lastActive else { return }
        lastActive = isActive
        onActiveChange?(isActive)
    }
}
