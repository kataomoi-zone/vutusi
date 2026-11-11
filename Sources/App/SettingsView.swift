import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var avatar: AvatarController
    let runtime: RuntimeState
    let installer: ExtensionInstaller
    @State private var cameras: [String] = []
    /// Mirrors only the preview, like a video app's self view; video apps get the frame as is.
    @AppStorage("mirrorPreview") private var mirrorPreview = false

    var body: some View {
        // The preview sits beside the form, large and never scrolled away, so the framing
        // and background can be adjusted while watching it.
        HStack(spacing: 0) {
            PreviewLayerView(layer: avatar.preview.layer)
                .scaleEffect(x: mirrorPreview ? -1 : 1, y: 1)
                .frame(width: 640, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Toggle(isOn: $mirrorPreview) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .toggleStyle(.button)
                    .help("Mirror the preview (video apps are not affected)")
                    .padding(8)
                }
                .padding(20)
            form
                .frame(width: 400)
        }
        .frame(height: 400)
        .onAppear {
            cameras = Self.physicalCameras()
            opensAtLogin = SMAppService.mainApp.status == .enabled
            // Tracking and rendering run while the preview shows, and stop when it closes.
            runtime.isPreviewOpen = true
        }
        .onDisappear { runtime.isPreviewOpen = false }
    }

    private var form: some View {
        Form {
            if avatar.cameraAccessDenied {
                Section {
                    Label("vutusi cannot use the camera, so the avatar does not move. "
                        + "Turn vutusi on in Privacy & Security > Camera, then let macOS reopen it.",
                        systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Privacy Settings…") { avatar.openCameraPrivacySettings() }
                }
            } else if let error = avatar.trackingError {
                Section {
                    Label("Tracking is not working, so the avatar does not move: \(error)",
                        systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Model") {
                Picker("Model", selection: $avatar.modelName) {
                    if avatar.models.isEmpty { Text("None").tag("") }
                    ForEach(avatar.models, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Spacer()
                    Button("Remove") { avatar.removeModel(avatar.modelName) }
                        .disabled(avatar.modelName.isEmpty)
                    Button("Add…") { avatar.addModel() }
                }
            }
            Section("Tracking") {
                Picker("Camera", selection: $avatar.cameraName) {
                    Text("Automatic").tag("")
                    ForEach(cameras, id: \.self) { Text($0).tag($0) }
                    // Keep a chosen camera that is unplugged right now selectable.
                    if !avatar.cameraName.isEmpty, !cameras.contains(avatar.cameraName) {
                        Text("\(avatar.cameraName) (not connected)").tag(avatar.cameraName)
                    }
                }
                LabeledContent("Smoothing") {
                    HStack {
                        Slider(value: $avatar.smoothing, in: 0...1)
                        Text(avatar.smoothing, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text("Higher is steadier but lags more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Follow") {
                    HStack {
                        Toggle("Face", isOn: tracks(.face))
                        Toggle("Torso", isOn: tracks(.body))
                        Toggle("Arms & Hands", isOn: tracks(.hands))
                    }
                }
            }
            Section("Framing") {
                LabeledContent("Zoom") {
                    Slider(value: $avatar.framing.zoom, in: 0.5...3) {
                    } minimumValueLabel: {
                        Text("Body")
                    } maximumValueLabel: {
                        Text("Face")
                    }
                }
                LabeledContent("Height") {
                    Slider(value: $avatar.framing.offset, in: -0.5...0.5)
                }
            }
            Section("Light") {
                LabeledContent("Direction") {
                    Slider(value: $avatar.light.azimuth, in: -90...90) {
                    } minimumValueLabel: {
                        Text("Left")
                    } maximumValueLabel: {
                        Text("Right")
                    }
                }
                LabeledContent("Height") {
                    Slider(value: $avatar.light.elevation, in: -30...80) {
                    } minimumValueLabel: {
                        Text("Low")
                    } maximumValueLabel: {
                        Text("High")
                    }
                }
                ColorPicker("Color", selection: lightColor, supportsOpacity: false)
                LabeledContent("Intensity") {
                    Slider(value: $avatar.light.intensity, in: 0.2...2)
                }
                Text("Models made with unlit materials ignore the light.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Background") {
                ColorPicker("Color", selection: backgroundColor, supportsOpacity: false)
                    .disabled(!avatar.backgroundImagePath.isEmpty)
                LabeledContent("Image") {
                    HStack {
                        Text(avatar.backgroundImagePath.isEmpty
                            ? "None" : URL(fileURLWithPath: avatar.backgroundImagePath).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { avatar.chooseBackgroundImage() }
                        if !avatar.backgroundImagePath.isEmpty {
                            Button("Remove") { avatar.removeBackgroundImage() }
                        }
                    }
                }
            }
            Section("Camera Extension") {
                LabeledContent("Status") {
                    HStack {
                        Text(installer.state.label)
                            .foregroundStyle(.secondary)
                        if installer.state == .installed {
                            Button("Uninstall") { installer.deactivate() }
                        } else {
                            Button("Install") { installer.activate() }
                                .disabled(!installer.needsAttention)
                        }
                    }
                }
            }
            Section {
                Toggle("Open at Login", isOn: openAtLogin)
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") { avatar.resetSettings() }
            }
        }
        .formStyle(.grouped)
    }

    /// Mirrors the system's login item rather than a setting of its own, read again each
    /// time the window opens, so turning vutusi off in System Settings > General > Login
    /// Items shows here too.
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    private var openAtLogin: Binding<Bool> {
        Binding {
            opensAtLogin
        } set: { enabled in
            try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func tracks(_ part: TrackingPart) -> Binding<Bool> {
        Binding {
            avatar.trackedParts.contains(part)
        } set: { on in
            if on { avatar.trackedParts.insert(part) } else { avatar.trackedParts.remove(part) }
        }
    }

    private var lightColor: Binding<Color> {
        Binding {
            let c = avatar.light.color
            return Color(.sRGB, red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            avatar.light.color = [Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent)]
        }
    }

    private var backgroundColor: Binding<Color> {
        Binding {
            let c = avatar.backgroundColor
            return Color(.sRGB, red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            avatar.backgroundColor = [Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent)]
        }
    }

    /// Cameras that can be tracked, leaving out vutusi Camera itself.
    private static func physicalCameras() -> [String] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.map(\.localizedName).filter { !$0.hasPrefix(CameraIdentifiers.deviceName) }
    }
}

/// Hosts a layer that is updated outside SwiftUI, so frames do not re-render the form.
private struct PreviewLayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
