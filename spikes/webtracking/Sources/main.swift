// Spike B: run MediaPipe in a WKWebView the user never sees, and log tracking rates.
//
// Arguments (all optional):
//   --serve scheme|http       vutusi:// via WKURLSchemeHandler, or http://127.0.0.1:<port>
//   --mode detached|offscreen|transparent|alpha0|visible
//                             no window / a window placed off every screen /
//                             an on-screen click-through window at alpha 0.01 or 0 / a normal window
//   --query "driver=raf&worker=1"
//   --duration 20             seconds before quitting
//   --log <path>              JSON lines are appended here

import AppKit
import Network
import WebKit

let arguments: [String: String] = {
    var result: [String: String] = [:]
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let key = it.next(), key.hasPrefix("--"), let value = it.next() {
        result[String(key.dropFirst(2))] = value
    }
    return result
}()
let serve = arguments["serve"] ?? "scheme"
let mode = arguments["mode"] ?? "detached"
let query = arguments["query"] ?? "driver=raf&worker=1"
let duration = Double(arguments["duration"] ?? "20")!
let logURL = URL(fileURLWithPath: arguments["log"] ?? "/tmp/webtracking.log")
let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web")

func log(_ object: [String: Any]) {
    var line = object
    line["t"] = Date().timeIntervalSince1970
    line["config"] = "\(serve) \(mode) \(query)"
    let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
    let handle = (try? FileHandle(forWritingTo: logURL)) ?? {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        return try! FileHandle(forWritingTo: logURL)
    }()
    handle.seekToEndOfFile()
    handle.write(data + Data("\n".utf8))
    try? handle.close()
}

func file(at path: String) -> (Data, String)? {
    let url = webRoot.appendingPathComponent(path.isEmpty || path == "/" ? "index.html" : path)
    guard url.standardized.path.hasPrefix(webRoot.standardized.path), let data = try? Data(contentsOf: url) else {
        return nil
    }
    let type = switch url.pathExtension {
    case "html": "text/html"
    case "js", "mjs": "text/javascript"
    case "wasm": "application/wasm"
    default: "application/octet-stream"
    }
    return (data, type)
}

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let path = task.request.url!.path
        guard let (data, type) = file(at: path) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(HTTPURLResponse(
            url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Minimal static file server on loopback, which browsers treat as a secure context.
final class LoopbackServer: @unchecked Sendable {
    let listener = try! NWListener(using: .tcp, on: .any)
    private let queue = DispatchQueue(label: "server")

    func start(ready: @escaping @Sendable (UInt16) -> Void) {
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map { String($0.split(separator: "?")[0]) } ?? "/"
                var response: Data
                if let (body, type) = file(at: path) {
                    response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                } else {
                    response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state, let port = listener.port?.rawValue { ready(port) }
        }
        listener.start(queue: queue)
    }
}

@MainActor
final class Spike: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    var webView: WKWebView!
    var window: NSWindow?
    let server = LoopbackServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "spike")
        configuration.setURLSchemeHandler(SchemeHandler(), forURLScheme: "vutusi")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isInspectable = true

        switch mode {
        case "visible":
            window = makeWindow(at: NSPoint(x: 100, y: 100))
        case "offscreen":
            window = makeWindow(at: NSPoint(x: -20000, y: -20000))
        case "transparent", "alpha0":
            // On screen and above other windows so it is not occluded, but invisible and click-through.
            let window = makeWindow(at: NSScreen.main!.visibleFrame.origin)
            window.alphaValue = mode == "alpha0" ? 0 : 0.01
            window.ignoresMouseEvents = true
            window.level = .statusBar
            self.window = window
        default:
            break
        }
        log(["type": "start", "windowVisible": window?.isVisible ?? false,
             "occlusionVisible": window?.occlusionState.contains(.visible) ?? false])

        if serve == "http" {
            server.start { port in
                Task { @MainActor in self.load("http://127.0.0.1:\(port)/index.html?\(query)") }
            }
        } else {
            load("vutusi://app/index.html?\(query)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { NSApp.terminate(nil) }
    }

    func makeWindow(at origin: NSPoint) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: webView.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        window.setFrameOrigin(origin)  // AppKit may constrain the initial frame on screen.
        return window
    }

    func load(_ string: String) {
        log(["type": "load", "url": string])
        webView.load(URLRequest(url: URL(string: string)!))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        var body = message.body as? [String: Any] ?? ["raw": "\(message.body)"]
        if let window {
            body["windowFrame"] = NSStringFromRect(window.frame)
            body["occlusionVisible"] = window.occlusionState.contains(.visible)
        }
        log(body)
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        log(["type": "mediaPermission", "origin": "\(origin.protocol)://\(origin.host):\(origin.port)"])
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        log(["type": "navigationError", "message": error.localizedDescription])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        log(["type": "navigationError", "message": error.localizedDescription])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log(["type": "webContentTerminated"])
    }
}

let app = NSApplication.shared
let delegate = Spike()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
