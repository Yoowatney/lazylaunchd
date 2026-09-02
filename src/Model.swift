// Value types the rest of the app is built on, plus the one shell helper that
// several of them need.

import SwiftUI
import AppKit

enum Schedule: Equatable {
    case daily(hour: Int, minute: Int)
    case interval(seconds: Int)
    case manual

    var label: String {
        switch self {
        case .daily(let h, let m): return String(format: "daily %02d:%02d", h, m)
        case .interval(let s):     return s % 3600 == 0 ? "every \(s / 3600)h" : "every \(s)s"
        case .manual:              return "manual"
        }
    }

    /// Next fire time, for the "next run in ..." line. Only calendar jobs get one:
    /// an interval job's phase depends on when launchd last started it, which is
    /// not something we can read, and a wrong countdown is worse than none.
    var nextFire: Date? {
        guard case .daily(let h, let m) = self else { return nil }
        let cal = Calendar.current
        var comps = DateComponents()
        comps.hour = h
        comps.minute = m
        return cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)
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
