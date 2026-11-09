import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var avatar: AvatarController
    @State private var cameras: [String] = []

    var body: some View {
        Form {
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
                            Button("Remove") { avatar.backgroundImagePath = "" }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") { avatar.resetSettings() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { cameras = Self.physicalCameras() }
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
