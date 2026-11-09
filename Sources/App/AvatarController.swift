import AppKit
import UniformTypeIdentifiers

/// Owns the renderer, the tracker that drives it, the model library and the settings,
/// which are kept in UserDefaults.
@MainActor
@Observable
final class AvatarController {
    private(set) var status = "none"
    @ObservationIgnored let renderer: AvatarRenderer?
    @ObservationIgnored let preview = Preview()
    @ObservationIgnored private(set) var tracker: WebTracker?
    @ObservationIgnored private let library = ModelLibrary()

    /// The models in the library.
    private(set) var models: [String] = []

    /// The model shown, by its name in the library; empty for none.
    var modelName = UserDefaults.standard.string(forKey: "modelName") ?? "" {
        didSet {
            guard modelName != oldValue else { return }
            UserDefaults.standard.set(modelName, forKey: "modelName")
            loadModel()
        }
    }

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

    var framing = Framing(
        zoom: UserDefaults.standard.object(forKey: "framingZoom") as? Float ?? 1,
        offset: UserDefaults.standard.float(forKey: "framingOffset")
    ) {
        didSet {
            UserDefaults.standard.set(framing.offset, forKey: "framingOffset")
            UserDefaults.standard.set(framing.zoom, forKey: "framingZoom")
            renderer?.framing = framing
        }
    }

    /// sRGB components of the solid background.
    var backgroundColor = UserDefaults.standard.array(forKey: "backgroundColor") as? [Float]
        ?? AvatarController.defaultBackgroundColor {
        didSet {
            UserDefaults.standard.set(backgroundColor, forKey: "backgroundColor")
            applyBackground()
        }
    }

    /// Shown instead of the color when set; the app's own copy (see setBackgroundImage).
    var backgroundImagePath = UserDefaults.standard.string(forKey: "backgroundImagePath") ?? "" {
        didSet {
            UserDefaults.standard.set(backgroundImagePath, forKey: "backgroundImagePath")
            applyBackground()
        }
    }

    /// animovi's default.
    static let defaultSmoothing: Float = 0.5
    static let defaultBackgroundColor: [Float] = [0.2, 0.6, 0.4]

    func resetSettings() {
        cameraName = ""
        smoothing = Self.defaultSmoothing
        framing = Framing()
        removeBackgroundImage()
        backgroundColor = Self.defaultBackgroundColor
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try setBackgroundImage(copying: url)
        } catch {
            status = "background image failed: \(error.localizedDescription)"
        }
    }

    func removeBackgroundImage() {
        try? setBackgroundImage(copying: nil)
    }

    /// Keeps one copy, Application Support/vutusi/background-<uuid>.<ext>. The new copy is
    /// made before the old ones go, so a failed copy keeps the current background, and
    /// choosing the current copy itself still works.
    private func setBackgroundImage(copying source: URL?) throws {
        let fileManager = FileManager.default
        var copy: URL?
        if let source {
            try fileManager.createDirectory(at: AppFiles.directory, withIntermediateDirectories: true)
            let destination = AppFiles.directory.appending(path: "background-\(UUID().uuidString).\(source.pathExtension)")
            try fileManager.copyItem(at: source, to: destination)
            copy = destination
        }
        let files = (try? fileManager.contentsOfDirectory(at: AppFiles.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("background") && file != copy {
            try? fileManager.removeItem(at: file)
        }
        backgroundImagePath = copy?.path ?? ""
    }

    private func applyBackground() {
        guard let renderer else { return }
        if !backgroundImagePath.isEmpty {
            do {
                try renderer.setBackgroundImage(URL(fileURLWithPath: backgroundImagePath))
                return
            } catch {
                status = "background image failed: \(error.localizedDescription)"
            }
        }
        let c = backgroundColor
        renderer.setBackground(red: c[0], green: c[1], blue: c[2])
    }

    init(bridge: VirtualCameraBridge) {
        do {
            renderer = try AvatarRenderer { [preview] frame in
                bridge.send(frame)
                preview.show(frame)
            }
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
        renderer?.framing = framing
        applyBackground()

        // Earlier builds remembered a path outside the library; bring that model in once.
        if let path = UserDefaults.standard.string(forKey: "modelPath") {
            UserDefaults.standard.removeObject(forKey: "modelPath")
            if modelName.isEmpty, let name = try? library.add(URL(fileURLWithPath: path)) {
                modelName = name
            }
        }
        models = library.names()
        loadModel()
    }

    /// Copies a VRM into the library and shows it.
    func addModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vrm") ?? .data]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        var added: String?
        for url in panel.urls {
            do {
                added = try library.add(url)
            } catch {
                status = "adding \(url.lastPathComponent) failed: \(error.localizedDescription)"
            }
        }
        models = library.names()
        if let added {
            if added == modelName { loadModel() } else { modelName = added }
        }
    }

    /// Deletes the library's copy; the original file stays where it was.
    func removeModel(_ name: String) {
        do {
            try library.remove(name)
        } catch {
            status = "removing \(name) failed: \(error.localizedDescription)"
        }
        models = library.names()
        if name == modelName { modelName = models.first ?? "" }
    }

    private func loadModel() {
        guard let renderer else { return }
        guard !modelName.isEmpty else {
            renderer.unload()
            status = "none"
            return
        }
        let name = modelName
        status = "loading \(name)"
        Task {
            do {
                try await renderer.load(library.url(for: name))
                if name == modelName { status = name }
            } catch {
                status = "\(name) failed: \(error.localizedDescription)"
            }
        }
    }
}

/// The rendered frames as a layer for the settings window.
@MainActor
final class Preview: Sendable {
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = .black
        return layer
    }()

    nonisolated func show(_ frame: CVPixelBuffer) {
        // The frame's IOSurface is shown as is, with no copy; it is read on the main
        // thread only and not written to until the pool hands it out again.
        nonisolated(unsafe) let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue()
        Task { @MainActor in layer.contents = surface }
    }
}
