import SwiftUI
import UniformTypeIdentifiers

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
        runtime.onActiveChange = { active in
            bridge.setSending(active)
            avatar.renderer?.setRunning(active)
            avatar.tracker?.setRunning(active)
        }
        _runtime = State(initialValue: runtime)
        _avatar = State(initialValue: avatar)
    }

    var body: some Scene {
        MenuBarExtra("vutusi", systemImage: runtime.isActive ? "video.fill" : "video") {
            MenuContent(runtime: runtime, avatar: avatar, installer: installer)
        }
        Settings {
            SettingsView(avatar: avatar)
        }
    }
}

private struct MenuContent: View {
    let runtime: RuntimeState
    let avatar: AvatarController
    let installer: ExtensionInstaller
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Camera: \(runtime.isSourceRunning ? "in use" : "idle")")
        Text("Model: \(avatar.status)")
        Text("Camera Extension: \(installer.status)")
        Divider()
        Button("Open VRM…") { avatar.chooseModel() }
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

/// Owns the renderer, the tracker that drives it, the chosen model and the tracking
/// settings, which are kept in UserDefaults.
/// LIMITATION: remembers the model by its path; Phase 4 copies models into Application Support.
@MainActor
@Observable
final class AvatarController {
    private(set) var status = "none"
    @ObservationIgnored let renderer: AvatarRenderer?
    @ObservationIgnored private(set) var tracker: WebTracker?
    @ObservationIgnored private let modelPathKey = "modelPath"

    /// The camera to track by name; empty picks one automatically.
    var cameraName = UserDefaults.standard.string(forKey: "cameraName") ?? "" {
        didSet {
            UserDefaults.standard.set(cameraName, forKey: "cameraName")
            tracker?.cameraName = cameraName
        }
    }

    var smoothing = UserDefaults.standard.object(forKey: "smoothing") as? Float ?? AvatarController.defaultSmoothing {
        didSet {
            UserDefaults.standard.set(smoothing, forKey: "smoothing")
            renderer?.smoothing = smoothing
        }
    }

    /// animovi's default.
    static let defaultSmoothing: Float = 0.5

    func resetSettings() {
        cameraName = ""
        smoothing = Self.defaultSmoothing
    }

    init(bridge: VirtualCameraBridge) {
        do {
            renderer = try AvatarRenderer { bridge.send($0) }
        } catch {
            renderer = nil
            status = "renderer failed: \(error.localizedDescription)"
            return
        }
        tracker = WebTracker { [renderer] result, faceMetrics, jsLatencyMs in
            renderer?.apply(result, faceMetrics: faceMetrics, jsLatencyMs: jsLatencyMs)
        }
        tracker?.cameraName = cameraName
        renderer?.smoothing = smoothing
        if let path = UserDefaults.standard.string(forKey: modelPathKey) {
            load(URL(fileURLWithPath: path))
        }
    }

    func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vrm") ?? .data]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: modelPathKey)
        load(url)
    }

    private func load(_ url: URL) {
        guard let renderer else { return }
        status = "loading \(url.lastPathComponent)"
        Task {
            do {
                try await renderer.load(url)
                status = url.lastPathComponent
            } catch {
                status = "failed: \(error.localizedDescription)"
            }
        }
    }
}
