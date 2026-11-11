import Observation

/// The one place that decides whether tracking and rendering run.
@MainActor
@Observable
final class RuntimeState {
    /// A video app is showing vutusi Camera.
    var isSourceRunning = false { didSet { if isSourceRunning != oldValue { onChange?(self) } } }

    /// The settings window shows the preview.
    var isPreviewOpen = false { didSet { if isPreviewOpen != oldValue { onChange?(self) } } }

    /// Tracking and rendering run while someone looks: a video app or the preview.
    var isActive: Bool { isSourceRunning || isPreviewOpen }

    /// Called whenever either input changes.
    @ObservationIgnored var onChange: ((RuntimeState) -> Void)?
}
