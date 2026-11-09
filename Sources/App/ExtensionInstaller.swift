import Foundation
import Observation
import SystemExtensions
import os

private let logger = Logger(subsystem: "com.kawarimidoll.vutusi", category: "ExtensionInstaller")
private let extensionID = "com.kawarimidoll.vutusi.CameraExtension"

@MainActor
@Observable
final class ExtensionInstaller: NSObject {
    private(set) var status = "unknown"

    init(activateOnLaunch: Bool) {
        super.init()
        if activateOnLaunch { activate() }
    }

    func activate() {
        submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main), label: "activating")
    }

    func deactivate() {
        submit(.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main), label: "deactivating")
    }

    private func submit(_ request: OSSystemExtensionRequest, label: String) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        update(label)
    }

    private func update(_ status: String) {
        logger.info("status: \(status, privacy: .public)")
        self.status = status
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
            update("waiting for approval in System Settings > General > Login Items & Extensions")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            switch result {
            case .completed: update("done")
            case .willCompleteAfterReboot: update("will complete after reboot")
            @unknown default: update("finished (\(result.rawValue))")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            update("failed: \(error.localizedDescription)")
        }
    }
}
