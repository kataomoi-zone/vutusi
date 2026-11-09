import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "com.kawarimidoll.vutusi", category: "WebTracker")

/// Runs the tracking page (web/) in a WKWebView nobody sees, and hands each solver
/// result to `onResult`.
///
/// The page must count as visible: in a web view without a window, or in a window off
/// screen, WebKit never resolves getUserMedia and throttles timers (Spike B). So the web
/// view sits in a window that is on screen but fully transparent and click-through.
@MainActor
final class WebTracker: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loaded = false
    private var wantsRunning = false
    /// Called when the page fails to open the camera, with the page's message.
    var onCameraError: ((String) -> Void)?
    /// The camera to track, by name; empty picks the first camera other than vutusi Camera.
    var cameraName = "" {
        didSet { if loaded { sendCameraName() } }
    }
    private let onResult: (HolisticResult, _ faceMetrics: [String: Float], _ jsLatencyMs: Double) -> Void

    init(onResult: @escaping (HolisticResult, [String: Float], Double) -> Void) {
        self.onResult = onResult
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "vutusi")
        let frame = NSRect(x: 0, y: 0, width: 160, height: 120)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        configuration.userContentController.add(self, name: "tracking")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif

        window.contentView = webView
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
        window.orderFrontRegardless()

        webView.load(URLRequest(url: URL(string: "vutusi://app/index.html")!))
    }

    /// Starts or stops the camera and tracking; the camera is released while stopped.
    func setRunning(_ running: Bool) {
        wantsRunning = running
        guard loaded else { return }
        webView.evaluateJavaScript(running ? "vutusi.start()" : "vutusi.stop()")
    }


    private func sendCameraName() {
        webView.callAsyncJavaScript(
            "await vutusi.setCamera(name)", arguments: ["name": cameraName], in: nil, in: .page)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String, let data = body.data(using: .utf8) else { return }
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
            logger.error("undecodable message: \(body.prefix(200), privacy: .public)")
            return
        }
        switch message.type {
        case "result":
            guard let result = message.result else { return }
            onResult(result, message.faceMetrics ?? [:], message.jsLatencyMs ?? 0)
        case "loaded":
            loaded = true
            sendCameraName()
            setRunning(wantsRunning)
        case "error" where message.message?.hasPrefix("camera:") == true:
            logger.error("page: \(message.message ?? body, privacy: .public)")
            onCameraError?(message.message ?? "")
        case "error":
            logger.error("page: \(message.message ?? body, privacy: .public)")
        default:
            logger.info("page: \(body, privacy: .public)")
        }
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        // Only the bundled page runs here, so it may use the camera the app was granted.
        decisionHandler(origin.protocol == "vutusi" ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.error("web content process terminated; reloading")
        loaded = false
        webView.reload()
    }

    /// Every message the page posts; fields beyond `type` depend on it.
    private struct Message: Decodable {
        var type: String
        var message: String?
        var result: HolisticResult?
        var faceMetrics: [String: Float]?
        var jsLatencyMs: Double?
    }
}

/// Serves the app bundle's `web` folder as vutusi://app/…, which WebKit treats as a
/// secure context (getUserMedia works) and which loads WASM and models with fetch,
/// unlike file://.
private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root = Bundle.main.resourceURL!.appendingPathComponent("web").standardizedFileURL

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = root.appendingPathComponent(task.request.url!.path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = switch url.pathExtension {
        case "html": "text/html"
        case "js", "mjs": "text/javascript"
        case "wasm": "application/wasm"
        default: "application/octet-stream"
        }
        task.didReceive(HTTPURLResponse(
            url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
