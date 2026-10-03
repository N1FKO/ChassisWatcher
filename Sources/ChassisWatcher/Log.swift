import Foundation

/// File+stdout logger with daily rotation and automatic cleanup of old logs.
///
/// Writes to ~/Library/Logs/ChassisWatcher/chassiswatcher.log - always the
/// current day's entries, so `tail -f` on that fixed path keeps working
/// across rotations. At local midnight (checked lazily, on the first write
/// after the rollover - there's no separate timer), the just-finished day's
/// content is renamed to chassiswatcher-YYYY-MM-DD.log and a fresh
/// chassiswatcher.log is started. Rotated (dated) logs older than
/// `retentionDays` are deleted automatically; the live chassiswatcher.log
/// itself is never deleted by this logic.
enum Log {
    // Default until config loads; PollingEngine calls updateRetentionDays(_:)
    // with the real config value at startup and on every live config reload.
    private static var retentionDays = 90

    private static let queue = DispatchQueue(label: "chassiswatcher.log")
    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()
    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private static let logsDir: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ChassisWatcher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var currentLogURL: URL { logsDir.appendingPathComponent("chassiswatcher.log") }

    // The calendar day (start-of-day) whose entries the open file handle
    // currently holds. Compared against "today" before every write.
    private static var currentLogDay: Date = Calendar.current.startOfDay(for: Date())

    private static var fileHandle: FileHandle? = {
        // If chassiswatcher.log already exists from a previous run (e.g. the
        // app was off overnight), archive it under the day it was actually
        // last written, before appending today's entries to a fresh file.
        rotateAtStartupIfStale()
        cleanupOldLogs()
        return openCurrentHandleForAppending()
    }()

    private static func openCurrentHandleForAppending() -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: currentLogURL.path) {
            fm.createFile(atPath: currentLogURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: currentLogURL)
        handle?.seekToEndOfFile()
        return handle
    }

    private static func rotateAtStartupIfStale() {
        let fm = FileManager.default
        let today = Calendar.current.startOfDay(for: Date())
        defer { currentLogDay = today }
        guard fm.fileExists(atPath: currentLogURL.path),
              let attrs = try? fm.attributesOfItem(atPath: currentLogURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return }
        let modDay = Calendar.current.startOfDay(for: modDate)
        if modDay < today {
            archiveCurrentLog(asDay: modDay)
        }
    }

    /// Renames the current chassiswatcher.log to a dated archive name.
    /// Only safe to call while no FileHandle is open on the current file.
    private static func archiveCurrentLog(asDay day: Date) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: currentLogURL.path) else { return }
        var archiveURL = logsDir.appendingPathComponent("chassiswatcher-\(dayFormatter.string(from: day)).log")
        // Extremely unlikely (would need two rotations for the same calendar
        // day), but avoid clobbering an existing archive just in case.
        var suffix = 2
        while fm.fileExists(atPath: archiveURL.path) {
            archiveURL = logsDir.appendingPathComponent("chassiswatcher-\(dayFormatter.string(from: day))-\(suffix).log")
            suffix += 1
        }
        try? fm.moveItem(at: currentLogURL, to: archiveURL)
    }

    private static func cleanupOldLogs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { return }
        guard let cutoff = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Calendar.current.startOfDay(for: Date())
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("chassiswatcher-"), name.hasSuffix(".log") else { continue }
            let datePart = String(name.dropFirst("chassiswatcher-".count).prefix(10))
            guard let fileDay = dayFormatter.date(from: datePart) else { continue }
            if fileDay < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Rotates the live file if local midnight has passed since it was last
    /// opened. Always called from inside `queue`, so it's serialized with
    /// respect to every write - no separate timer needed.
    private static func rotateIfDayChanged() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today > currentLogDay else { return }
        let finishedDay = currentLogDay
        fileHandle?.closeFile()
        archiveCurrentLog(asDay: finishedDay)
        currentLogDay = today
        fileHandle = openCurrentHandleForAppending()
        cleanupOldLogs()
    }

    private static func write(_ level: String, _ message: String) {
        queue.sync {
            rotateIfDayChanged()
            let line = "[\(dateFormatter.string(from: Date()))] [\(level)] \(message)\n"
            print(line, terminator: "")
            if let handle = fileHandle {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            }
        }
    }

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    /// Applies a (possibly new) retention window from config, and re-runs
    /// cleanup immediately so a shortened window takes effect right away
    /// instead of waiting for the next midnight rotation.
    static func updateRetentionDays(_ days: Int) {
        queue.sync {
            guard days != retentionDays else { return }
            retentionDays = days
            cleanupOldLogs()
        }
    }
}
