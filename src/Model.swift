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

    var label: String {
        switch self {
        case .daily(let times):
            let shown = times.prefix(3).map(\.text).joined(separator: ", ")
            let rest = times.count - 3
            return rest > 0 ? "daily \(shown) +\(rest)" : "daily \(shown)"
        case .interval(let s):
            return s % 3600 == 0 ? "every \(s / 3600)h" : "every \(s)s"
        case .manual:
            return "manual"
        }
    }

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

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}
