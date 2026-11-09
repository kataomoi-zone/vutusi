import Foundation

/// Files the app keeps its own copies of in Application Support, so that moving or
/// deleting the originals loses nothing.
enum AppFiles {
    static let directory = URL.applicationSupportDirectory.appending(path: "vutusi", directoryHint: .isDirectory)
}

/// The user's VRM models, copied into Application Support/vutusi/Models.
struct ModelLibrary {
    let directory = AppFiles.directory.appending(path: "Models", directoryHint: .isDirectory)

    /// File names, sorted for display.
    func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.lowercased().hasSuffix(".vrm") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    /// Copies the file in under its own name, replacing a model of the same name. The copy
    /// goes to a temporary name first, so a failed copy keeps the model it would replace.
    func add(_ source: URL) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.lastPathComponent
        let destination = url(for: name)
        // Adding the library's own copy, picked from its folder, changes nothing.
        guard source.standardizedFileURL != destination.standardizedFileURL else { return name }
        let temporary = directory.appending(path: ".\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return name
    }

    /// Deletes the app's copy only; the file it was added from is untouched.
    func remove(_ name: String) throws {
        try FileManager.default.removeItem(at: url(for: name))
    }
}
