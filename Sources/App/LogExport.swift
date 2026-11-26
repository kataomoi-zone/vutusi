import AppKit
import OSLog
import UniformTypeIdentifiers

/// Saves this run's log entries to a file the user picks, for a problem report.
///
/// LIMITATION: only this process since launch, and only what macOS still holds: info
/// entries live in memory and the oldest are dropped. The Camera Extension runs in its
/// own process and is left out; README's `log stream` command covers both.
@MainActor
func saveLogs() {
    let panel = NSSavePanel()
    // Local time without separators, e.g. vutusi-20261126T083805.log: no colons in a file name.
    let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
    panel.nameFieldStringValue = "vutusi-\(stamp).log"
    panel.allowedContentTypes = [.log]
    // A menu bar app is not active, so the panel would open behind other windows.
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        // Filtered by the store: the process also logs for WebKit and RealityKit.
        let lines = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", logSubsystem))
            .compactMap { $0 as? OSLogEntryLog }
            .map { "\($0.date.ISO8601Format()) [\($0.category)] \($0.composedMessage)" }
        try ([systemSummary] + lines).joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    } catch {
        NSAlert(error: error).runModal()
    }
}
