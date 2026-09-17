//
//  DiagnosticLogger.swift
//  FloeBar
//

import Foundation
import OSLog

/// A centralized diagnostic logger that writes log messages to a file on disk
/// when diagnostic logging is enabled. This lets users capture detailed logs
/// for troubleshooting without needing a debug build.
///
/// Diagnostic logging is disabled by default. When disabled, ``log(level:category:message:)``
/// is a cheap no-op, so the app's existing logging incurs no file I/O.
///
/// Log files are written to `~/Library/Logs/FloeBar/`.
final class DiagnosticLogger: @unchecked Sendable {
    /// The shared diagnostic logger instance.
    static let shared = DiagnosticLogger()

    /// Whether diagnostic logging to file is currently enabled. Thread-safe.
    private let isEnabledLock = OSAllocatedUnfairLock(initialState: false)

    var isEnabled: Bool {
        get { isEnabledLock.withLock { $0 } }
        set {
            let oldValue = isEnabledLock.withLock { current -> Bool in
                let old = current
                current = newValue
                return old
            }
            if newValue && !oldValue {
                openLogFile()
            } else if !newValue && oldValue {
                closeLogFile()
            }
        }
    }

    /// The directory where log files are stored.
    var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("FloeBar", isDirectory: true)
    }

    /// Whether any log files exist in the log directory.
    var hasLogFiles: Bool {
        latestLogFile != nil
    }

    /// The most recent log file in the log directory, if any.
    var latestLogFile: URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }
        return contents
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    /// The current log file URL, if logging is active.
    private let currentLogFileLock = OSAllocatedUnfairLock<URL?>(initialState: nil)

    var currentLogFile: URL? {
        currentLogFileLock.withLock { $0 }
    }

    /// The file handle for writing.
    private let fileHandleLock = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)

    /// Internal logger for `DiagnosticLogger`'s own messages.
    private let osLog = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.evanzhu.FloeBar",
        category: "DiagnosticLogger"
    )

    /// Date formatter for log timestamps.
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Date formatter for log file names.
    private let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Serial queue for file I/O.
    private let writeQueue = DispatchQueue(
        label: "com.evanzhu.FloeBar.DiagnosticLogger.writeQueue",
        qos: .utility
    )

    private init() {}

    // MARK: - File Management

    /// Creates the log directory if needed and opens a new log file.
    private func openLogFile() {
        let dir = logDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            osLog.error("Failed to create log directory at \(dir.path, privacy: .public): \(error, privacy: .public)")
            return
        }

        let fileName = "floebar_\(fileNameFormatter.string(from: Date())).log"
        let fileURL = dir.appendingPathComponent(fileName)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            fileHandleLock.withLock { $0 = handle }
            currentLogFileLock.withLock { $0 = fileURL }

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            let header = """
            ========================================
            FloeBar Diagnostic Log
            Started: \(timestampFormatter.string(from: Date()))
            Version: \(version) (\(build))
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            ========================================\n\n
            """
            if let data = header.data(using: .utf8) {
                handle.write(data)
            }

            osLog.info("Diagnostic logging started: \(fileURL.path, privacy: .public)")
        } catch {
            osLog.error("Failed to open log file at \(fileURL.path, privacy: .public): \(error, privacy: .public)")
        }

        // Keep only the most recent log files.
        cleanupOldLogFiles(in: dir, keepCount: 5)
    }

    /// Closes the current log file.
    private func closeLogFile() {
        fileHandleLock.withLock { handle in
            if let handle {
                let footer = "\n\(timestampFormatter.string(from: Date())) [DiagnosticLogger] Diagnostic logging stopped\n"
                if let data = footer.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            }
            handle = nil
        }
        currentLogFileLock.withLock { $0 = nil }
        osLog.info("Diagnostic logging stopped")
    }

    /// Removes old log files, keeping only the most recent `keepCount`.
    private func cleanupOldLogFiles(in directory: URL, keepCount: Int) {
        writeQueue.async { [weak self] in
            guard let self else {
                return
            }
            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.creationDateKey],
                    options: .skipsHiddenFiles
                )
                let logFiles = files
                    .filter { $0.pathExtension == "log" }
                    .sorted { lhs, rhs in
                        let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                        return lhsDate > rhsDate
                    }
                if logFiles.count > keepCount {
                    for file in logFiles.dropFirst(keepCount) {
                        try FileManager.default.removeItem(at: file)
                    }
                }
            } catch {
                osLog.warning("Failed to clean up old log files: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Logging

    /// Log levels matching OSLog conventions.
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case notice = "NOTICE"
        case warning = "WARNING"
        case error = "ERROR"
    }

    /// Writes a log message to the diagnostic log file.
    ///
    /// This is a no-op when diagnostic logging is disabled.
    ///
    /// - Parameters:
    ///   - level: The severity level.
    ///   - category: The logger category (e.g. "MenuBarItemManager").
    ///   - message: The log message.
    func log(level: Level, category: String, message: String) {
        guard isEnabled else {
            return
        }

        let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        writeQueue.async { [weak self] in
            self?.fileHandleLock.withLock { handle in
                handle?.write(data)
            }
        }
    }
}
