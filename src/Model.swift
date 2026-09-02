// Value types the rest of the app is built on, plus the one shell helper that
// several of them need.

import SwiftUI
import AppKit

struct TimeOfDay: Equatable, Hashable, Comparable, Identifiable {
    var hour: Int
    var minute: Int

    var id: Int { hour * 60 + minute }
    var text: String { String(format: "%02d:%02d", hour, minute) }
    static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.id < b.id }
}

enum Schedule: Equatable {
    /// launchd lets StartCalendarInterval be an array, and a job that runs at 09:00,
    /// 18:00 and 21:00 is an ordinary thing to want. Reading only the first entry
    /// misreported those jobs, and writing a single entry back deleted the rest.
    case daily([TimeOfDay])
    case interval(seconds: Int)
    case manual

    static func daily(hour: Int, minute: Int) -> Schedule {
        .daily([TimeOfDay(hour: hour, minute: minute)])
    }

    var times: [TimeOfDay] {
        if case .daily(let t) = self { return t }
        return []
    }

    /// Short enough for the sidebar, where the row is narrow and a status suffix may
    /// follow. Listing even three times overflowed the row, and the truncation ate the
    /// "+N" that was supposed to say more existed - so past one time this shows the
    /// first and a count, which is a predictable width. `fullLabel` is the tooltip.
    var label: String {
        guard case .daily(let times) = self, times.count > 1 else { return fullLabel }
        return "daily \(times[0].text) +\(times.count - 1)"
    }

    /// Every time, spelled out. Used in the detail pane, which has the room, and as
    /// the tooltip behind the abbreviated form.
    var fullLabel: String {
        switch self {
        case .daily(let times):
            return "daily " + times.map(\.text).joined(separator: ", ")
        case .interval(let s):
            return s % 3600 == 0 ? "every \(s / 3600)h" : "every \(s)s"
        case .manual:
            return "manual"
        }
    }

    /// True when `label` had to leave something out.
    var isAbbreviated: Bool { label != fullLabel }

    /// Soonest of the scheduled times, for the "next run in ..." line. Interval jobs
    /// get none: their phase depends on when launchd last started them, which is not
    /// readable, and a wrong countdown is worse than no countdown.
    var nextFire: Date? {
        guard case .daily(let times) = self, !times.isEmpty else { return nil }
        let cal = Calendar.current
        return times.compactMap { t in
            cal.nextDate(after: Date(),
                         matching: DateComponents(hour: t.hour, minute: t.minute),
                         matchingPolicy: .nextTime)
        }.min()
    }
}

struct Job: Identifiable, Hashable {
    let label: String
    let plistPath: String
    let schedule: Schedule
    /// Files this job might write to. launchd's StandardOutPath is often an empty
    /// capture file while the real record goes to a log the script opens itself,
    /// so we keep every candidate and later show whichever one actually grew.
    let logCandidates: [String]

    var id: String { label }
    var shortName: String {
        label.hasPrefix("com.") ? String(label.dropFirst(4)) : label
    }

    static func == (a: Job, b: Job) -> Bool { a.label == b.label }
    func hash(into h: inout Hasher) { h.combine(label) }
}

enum JobState {
    case idle(exit: Int)   // loaded, last run finished with this code
    case notLoaded         // in ~/Library/LaunchAgents but not registered
    case running

    var color: Color {
        switch self {
        case .running:          return .accentColor
        case .notLoaded:        return .secondary
        case .idle(let e):      return e == 0 ? .green : .orange
        }
    }
}

// MARK: - Shell

/// Everything a command said, rather than half of it. The previous version returned
/// stdout alone and gave stderr a pipe it never read, so a failing launchctl - which
/// says nothing on stdout and reports itself on stderr with a non-zero status -
/// arrived here as an empty string and was indistinguishable from success.
struct Output {
    let stdout: String
    let stderr: String
    let status: Int32

    var ok: Bool { status == 0 }

    /// What to show a person. launchctl is not always talkative when it fails, so the
    /// status is the fallback rather than an empty line.
    var message: String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "launchctl exited with status \(status)." : trimmed
    }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> Output {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch {
        return Output(stdout: "", stderr: error.localizedDescription, status: -1)
    }
    // Both pipes are drained at once. Reading one to the end and then the other
    // deadlocks the moment a process fills the pipe nobody is reading: it blocks on
    // the write, so it never closes the pipe we are blocked on.
    var errData = Data()
    let draining = DispatchGroup()
    draining.enter()
    DispatchQueue.global().async {
        errData = err.fileHandleForReading.readDataToEndOfFile()
        draining.leave()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    draining.wait()
    p.waitUntilExit()
    return Output(stdout: String(data: outData, encoding: .utf8) ?? "",
                  stderr: String(data: errData, encoding: .utf8) ?? "",
                  status: p.terminationStatus)
}
