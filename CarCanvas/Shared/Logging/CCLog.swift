import Foundation
import os
import UIKit

/// In-memory session log for on-device troubleshooting.
///
/// Lifecycle: a session-start line is written when the app launches, and the
/// buffer is cleared when the app exits, so a fresh launch always starts from an
/// empty log. It survives backgrounding so it can still be copied out.
enum CCLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.carcanvas.wq"
    private static let logger = Logger(subsystem: subsystem, category: "CarCanvas")

    private static let lock = NSLock()
    private static var lines: [String] = []
    private static var started = false
    private static let maxLines = 4000

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Call once at launch. Also installs the lifecycle observers.
    static func startSession() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        lines.removeAll()

        appendLocked("session start | iOS \(WQCompatibility.versionString) | \(WQCompatibility.supportSummary)")
        appendLocked("bundle=\(Bundle.main.bundleIdentifier ?? "-") version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")

        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            CCLog.event("app will terminate -> clearing session log")
            CCLog.clear()
        }
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(message, level: "INFO")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append(message, level: "ERROR")
    }

    static func event(_ message: String) {
        append(message, level: "EVENT")
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }

    /// Snapshot for the viewer. Never includes file contents or private data.
    static func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    private static func append(_ message: String, level: String) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked("\(formatter.string(from: Date())) [\(level)] \(message)")
    }

    /// Caller must hold `lock`.
    private static func appendLocked(_ line: String) {
        if lines.count >= maxLines { lines.removeFirst(lines.count - maxLines + 1) }
        lines.append(line)
    }
}
