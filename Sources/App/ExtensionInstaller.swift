import Foundation
import Observation
import SystemExtensions
import os

private let logger = Logger(subsystem: "com.kawarimidoll.vutusi", category: "ExtensionInstaller")
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

    /// The camera is unavailable and nothing is under way to change that, so the user has to act.
    var needsAttention: Bool {
        switch state {
        case .installed, .activating, .deactivating: false
        default: true
        }
    }

    /// Activates right away, which installs the extension on first launch and replaces an
    /// installed one of another version (each `scripts/dev.sh` run, each update).
    override init() {
        super.init()
        activate()
    }

    func activate() {
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
            switch result {
            case .completed: update(state == .deactivating ? .uninstalled : .installed)
            case .willCompleteAfterReboot: update(.needsReboot)
            @unknown default: update(.failed("unknown result \(result.rawValue)"))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            update(.failed(error.localizedDescription))
        }
    }
}
