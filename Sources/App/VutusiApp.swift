import SwiftUI

@main
struct VutusiApp: App {
    // Activates on launch so that each `scripts/dev.sh` run replaces the installed extension.
    @State private var installer = ExtensionInstaller(activateOnLaunch: true)
    @State private var runtime = RuntimeState()
    private let bridge: VirtualCameraBridge

    init() {
        let runtime = RuntimeState()
        let pattern = TestPattern()
        let bridge = VirtualCameraBridge(makeFrame: pattern.nextFrame) { running in
            Task { @MainActor in runtime.isSourceRunning = running }
        }
        runtime.onActiveChange = { bridge.setSending($0) }
        _runtime = State(initialValue: runtime)
        self.bridge = bridge
    }

    var body: some Scene {
        MenuBarExtra("vutusi", systemImage: runtime.isActive ? "video.fill" : "video") {
            Text("Camera: \(runtime.isSourceRunning ? "in use" : "idle")")
            Text("Camera Extension: \(installer.status)")
            Divider()
            Button("Install Camera Extension") { installer.activate() }
            Button("Uninstall Camera Extension") { installer.deactivate() }
            Divider()
            Button("Quit vutusi") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
