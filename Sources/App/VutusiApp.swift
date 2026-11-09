import SwiftUI

@main
struct VutusiApp: App {
    // Activates on launch so that each `scripts/dev.sh` run replaces the installed extension.
    @State private var installer = ExtensionInstaller(activateOnLaunch: true)
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
            SettingsView(avatar: avatar, runtime: runtime)
        }
    }
}

private struct MenuContent: View {
    let runtime: RuntimeState
    @Bindable var avatar: AvatarController
    let installer: ExtensionInstaller
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Camera: \(runtime.isSourceRunning ? "in use" : "idle")")
        Text("Model: \(avatar.status)")
        Text("Camera Extension: \(installer.status)")
        Divider()
        Picker("Model", selection: $avatar.modelName) {
            ForEach(avatar.models, id: \.self) { Text($0).tag($0) }
        }
        Button("Add Model…") { avatar.addModel() }
        Button("Settings…") {
            // A menu bar app is not active, so its settings window would open behind others.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Install Camera Extension") { installer.activate() }
        Button("Uninstall Camera Extension") { installer.deactivate() }
        Divider()
        Button("Quit vutusi") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
