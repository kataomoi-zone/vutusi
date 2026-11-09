import SwiftUI

@main
struct VutusiApp: App {
    // Activates on launch so that each `scripts/dev.sh` run replaces the installed extension.
    @State private var installer = ExtensionInstaller(activateOnLaunch: true)

    var body: some Scene {
        MenuBarExtra("vutusi", systemImage: "video.fill") {
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
