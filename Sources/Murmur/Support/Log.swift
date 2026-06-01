import Foundation
import os

/// Thin wrapper over the unified logging system so we have one place to adjust
/// logging later.
enum Log {
    private static let logger = Logger(subsystem: "com.murmur.app", category: "murmur")

    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
