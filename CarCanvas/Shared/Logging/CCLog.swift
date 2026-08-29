import Foundation
import os

enum CCLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.carcanvas.wq"
    private static let logger = Logger(subsystem: subsystem, category: "CarCanvas")

    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
