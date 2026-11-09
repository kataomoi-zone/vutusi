import Foundation

/// Identifiers shared by the app and the Camera Extension.
enum CameraIdentifiers {
    // Meet / Slack remember the selected camera by these IDs, so they must stay fixed.
    static let deviceID = UUID(uuidString: "F34B316E-4D3A-4717-B767-6C57EFDB36F4")!
    static let sourceStreamID = UUID(uuidString: "6CF13C9E-9796-4921-B060-53A33A146C14")!
    static let sinkStreamID = UUID(uuidString: "FA6775C0-0920-416B-8840-90F8D8AB42DF")!

    static let deviceName = "vutusi Camera"
    static let sourceStreamName = "vutusi Camera.Source"
    static let sinkStreamName = "vutusi Camera.Sink"

    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameRate: Int32 = 30
}
