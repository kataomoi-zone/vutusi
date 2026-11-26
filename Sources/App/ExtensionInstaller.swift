import AppKit
import Observation
import SystemExtensions
import os

private let logger = Logger(subsystem: logSubsystem, category: "ExtensionInstaller")
private let extensionID = "com.kawarimidoll.vutusi.CameraExtension"

@MainActor
@Observable
final class ExtensionInstaller: NSObject {
    enum State: Equatable {
        case activating, deactivating, waitingForApproval, installed, uninstalled, needsReboot
        case failed(String)

        var label: String {
            switch self {
            case .activating: "installing…"
            case .deactivating: "uninstalling…"
            case .waitingForApproval: "waiting for approval in System Settings > General > Login Items & Extensions"
            case .installed: "installed"
            case .uninstalled: "not installed"
            case .needsReboot: "restart the Mac to finish"
            case .failed(let message): "failed: \(message)"
            }
        }
    }

    private(set) var state = State.uninstalled
    /// The request under way is replacing an installed extension of another version.
    private var isReplacing = false
    /// Off in an app that was relaunched, for the activation at its launch: were the camera
    /// still missing there, relaunching again would only loop.
    private var mayRelaunch = !CommandLine.arguments.contains(relaunchedArgument)
    private var isWaitingToRelaunch = false

    /// The camera is unavailable and nothing is under way to change that, so the user has to act.
    var needsAttention: Bool {
        switch state {
        case .installed, .activating, .deactivating: false
        default: true
        }
    }

    /// Activates right away, which installs the extension on first launch and replaces an
    /// installed one of another version (a build whose extension files changed).
    override init() {
        super.init()
        submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main), state: .activating)
    }

    func activate() {
        mayRelaunch = true
        submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main), state: .activating)
    }

    func deactivate() {
        submit(.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main), state: .deactivating)
    }

    private func submit(_ request: OSSystemExtensionRequest, state: State) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        update(state)
    }

    private func update(_ state: State) {
        logger.info("state: \(state.label, privacy: .public)")
        self.state = state
    }

    /// A process never sees a camera that appeared after it started: not the one that
    /// replaced the extension, and not one started before the new camera is registered,
    /// which takes a moment after the request completes. So the app starts itself as a
    /// probe until a new process does see the camera, and only then relaunches.
    private func relaunchWhenCameraAppears() {
        guard mayRelaunch, !isWaitingToRelaunch else { return }
        isWaitingToRelaunch = true
        Task {
            for attempt in 1...60 {
                if await Self.newProcessSeesCamera() {
                    logger.info("a new process sees the camera (attempt \(attempt))")
                    return relaunch()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            isWaitingToRelaunch = false
            update(.failed("the camera did not appear; quit and reopen Vutusi"))
        }
    }

    nonisolated static let probeArgument = "--probe-camera"
    private nonisolated static let relaunchedArgument = "--relaunched"

    private nonisolated static func newProcessSeesCamera() async -> Bool {
        await withCheckedContinuation { continuation in
            let probe = Process()
            probe.executableURL = Bundle.main.executableURL
            probe.arguments = [probeArgument]
            probe.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try probe.run() } catch { continuation.resume(returning: false) }
        }
    }

    private func relaunch() {
        logger.info("relaunching to pick up the camera")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Self.relaunchedArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    self.isWaitingToRelaunch = false
                    self.update(.failed("could not relaunch (\(error.localizedDescription)); quit and reopen Vutusi"))
                }
                return
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

// Requests are created with `queue: .main`, so every callback already runs on the main actor.
extension ExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        logger.info(
            "replacing \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        MainActor.assumeIsolated { isReplacing = true }
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            update(.waitingForApproval)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            let replaced = isReplacing
            isReplacing = false
            switch result {
            case .completed:
                update(state == .deactivating ? .uninstalled : .installed)
                if state == .installed, replaced || virtualCameraDevice() == nil { relaunchWhenCameraAppears() }
            case .willCompleteAfterReboot: update(.needsReboot)
            @unknown default: update(.failed("unknown result \(result.rawValue)"))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            isReplacing = false
            update(.failed(error.localizedDescription))
        }
    }
}
