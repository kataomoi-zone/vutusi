import SwiftUI

@main
struct VutusiApp: App {
    @State private var installer = ExtensionInstaller()
    @State private var runtime: RuntimeState
    @State private var avatar: AvatarController

    init() {
        let runtime = RuntimeState()
        let bridge = VirtualCameraBridge { running in
            Task { @MainActor in runtime.isSourceRunning = running }
        }
        let avatar = AvatarController(bridge: bridge)
        runtime.onChange = { runtime in
            // Only a video app drains the sink, so the preview alone sends nothing there.
            bridge.setSending(runtime.isSourceRunning)
            avatar.renderer?.setRunning(runtime.isActive)
            avatar.tracker?.setRunning(runtime.isActive)
        }
        _runtime = State(initialValue: runtime)
        _avatar = State(initialValue: avatar)
    }

    var body: some Scene {
        MenuBarExtra("vutusi", systemImage: runtime.isActive ? "video.fill" : "video") {
            MenuContent(runtime: runtime, avatar: avatar, installer: installer)
        }
        Settings {
            SettingsView(avatar: avatar, runtime: runtime, installer: installer)
        }
    }
}

private struct MenuContent: View {
    let runtime: RuntimeState
    @Bindable var avatar: AvatarController
    let installer: ExtensionInstaller
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Problems come first and only while they last; the rest of the time the menu is
        // the status and what is switched often. Everything else is in Settings.
        if installer.needsAttention {
            Label("Camera Extension: \(installer.state.label)", systemImage: "exclamationmark.triangle")
            Button("Install Camera Extension") { installer.activate() }
            Divider()
        } else if installer.state != .installed {
            Text("Camera Extension: \(installer.state.label)")
            Divider()
        }
        if avatar.cameraAccessDenied {
            Label("Camera access is off; the avatar does not move", systemImage: "exclamationmark.triangle")
            Button("Allow Camera Access…") { avatar.openCameraPrivacySettings() }
            Divider()
        } else if let error = avatar.trackingError {
            Label("Tracking: \(error)", systemImage: "exclamationmark.triangle")
            Divider()
        }
        Text("Camera: \(runtime.isSourceRunning ? "in use" : "idle")")
        Text("Model: \(avatar.status)")
        Divider()
        if avatar.models.isEmpty {
            Button("Add Model…") { avatar.addModel() }
        } else {
            Picker("Model", selection: $avatar.modelName) {
                ForEach(avatar.models, id: \.self) { Text($0).tag($0) }
            }
        }
        Button("Settings…") {
            // A menu bar app is not active, so its settings window would open behind others.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit vutusi") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
