//
//  Logging.swift
//  FloeBar
//

import OSLog

/// A type that encapsulates logging behavior for Ice.
///
/// Every message is written to the unified system log (via `os.Logger`). When
/// diagnostic logging is enabled in settings, the same message is additionally
/// written to a log file on disk by ``DiagnosticLogger``. When diagnostic
/// logging is disabled, the file write is a cheap no-op.
struct Logger {
    /// The unified logger at the base of this logger.
    private let base: os.Logger

    /// The category, forwarded to the diagnostic logger for on-disk logs.
    private let category: String

    /// Creates a logger for Ice using the specified category.
    init(category: String) {
        self.base = os.Logger(subsystem: Constants.bundleIdentifier, category: category)
        self.category = category
    }

    /// Logs the given informative message to the logger.
    func info(_ message: @autoclosure () -> String) {
        let message = message()
        base.info("\(message, privacy: .public)")
        DiagnosticLogger.shared.log(level: .info, category: category, message: message)
    }

    /// Logs the given debug message to the logger.
    func debug(_ message: @autoclosure () -> String) {
        let message = message()
        base.debug("\(message, privacy: .public)")
        DiagnosticLogger.shared.log(level: .debug, category: category, message: message)
    }

    /// Logs the given notice message to the logger.
    func notice(_ message: @autoclosure () -> String) {
        let message = message()
        base.notice("\(message, privacy: .public)")
        DiagnosticLogger.shared.log(level: .notice, category: category, message: message)
    }

    /// Logs the given error message to the logger.
    func error(_ message: @autoclosure () -> String) {
        let message = message()
        base.error("\(message, privacy: .public)")
        DiagnosticLogger.shared.log(level: .error, category: category, message: message)
    }

    /// Logs the given warning message to the logger.
    func warning(_ message: @autoclosure () -> String) {
        let message = message()
        base.warning("\(message, privacy: .public)")
        DiagnosticLogger.shared.log(level: .warning, category: category, message: message)
    }
}
