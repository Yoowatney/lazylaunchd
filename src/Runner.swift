// Starts an agent and follows whatever it writes to its log.

import SwiftUI
import Foundation

@MainActor
final class Runner: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var states: [String: JobState] = [:]
    /// Keyed by label, because one shared string showed the last run's log under
    /// whichever agent you selected next - reading as if that agent had produced it.
    /// Keeping them apart also means switching away and back does not lose a log.
    @Published private(set) var outputs: [String: String] = [:]
    @Published private(set) var activeLogs: [String: String] = [:]
    @Published var isRunning = false

    private var offset: UInt64 = 0
    private var watchedLog: String?
    private var timer: Timer?
    private var runningLabel: String?
    private var loaded: Set<String> = []
    private var truncatedLogs: [String: Bool] = [:]

    /// How much of an existing log to read in. Enough to see the last several runs,
    /// small enough that selecting an agent whose log has grown for months does not
    /// stall on reading it.
    static let tailBytes: UInt64 = 128 * 1024

    func refresh() {
        jobs = Agents.load()
        states = Agents.states()
        // Drop what was read in so a log written by a scheduled run since the app
        // opened shows up. Deliberately part of Refresh rather than automatic: nobody
        // wants the pane they are reading to move on its own.
        outputs.removeAll()
        activeLogs.removeAll()
        loaded.removeAll()
    }

    /// Reads the tail of whatever the agent has already written, so selecting it shows
    /// its history rather than an empty pane. Without this the only way to tell whether
    /// a scheduled run had worked was to run it again by hand and watch.
    func preload(_ job: Job) {
        guard !loaded.contains(job.label) else { return }
        loaded.insert(job.label)

        // The run path learns which file to follow by watching which one grows. Nothing
        // is growing yet, so go by which was written most recently.
        let existing = job.logCandidates
            .map { ($0, modified($0), fileSize($0)) }
            .filter { $0.2 > 0 }
            .sorted { $0.1 > $1.1 }
        guard let (path, _, size) = existing.first else { return }

        let from = size > Runner.tailBytes ? size - Runner.tailBytes : 0
        guard var text = read(path, from: from), !text.isEmpty else { return }
        // Starting mid-file almost certainly lands mid-line; drop the fragment rather
        // than showing half a line as though it were one.
        if from > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        outputs[job.label] = text
        activeLogs[job.label] = path
        truncatedLogs[job.label] = from > 0
    }

    /// True when the pane is showing only the end of a longer log.
    func isTruncated(_ job: Job) -> Bool { truncatedLogs[job.label] == true }

    func output(for job: Job) -> String { outputs[job.label] ?? "" }
    func activeLog(for job: Job) -> String? { activeLogs[job.label] }

    /// True only for the agent actually running, so the log pane's "live" marker
    /// does not appear on every agent while one of them runs.
    func isRunning(_ job: Job) -> Bool { isRunning && runningLabel == job.label }

    func state(for job: Job) -> JobState {
        if isRunning, runningLabel == job.label { return .running }
        return states[job.label] ?? .notLoaded
    }

    func start(_ job: Job) {
        guard !isRunning else { return }
        // The existing log stays on screen and the new run appends to it, which is what
        // the file itself does. Clearing here was why a run erased the history that had
        // just been read in.
        preload(job)
        isRunning = true
        runningLabel = job.label

        // Snapshot every candidate so we can tell which file this run writes to.
        let sizes = job.logCandidates.reduce(into: [String: UInt64]()) { acc, path in
            acc[path] = fileSize(path)
        }

        // launchctl start refuses a job that is not loaded, and says so on stderr with
        // a non-zero status. Checking stdout instead meant that failure looked like a
        // successful run, and the log poll below then reported it as an agent that had
        // simply printed nothing.
        let started = run("/bin/launchctl", ["start", job.label])
        if !started.ok {
            outputs[job.label] = "Could not start \(job.label):\n\(started.message)"
            isRunning = false
            runningLabel = nil
            states = Agents.states()
            return
        }

        watchedLog = nil
        offset = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(job, sizes) }
        }
    }

    private func tick(_ job: Job, _ before: [String: UInt64]) {
        // Latch onto the first candidate that grows, then follow only that one.
        if watchedLog == nil {
            for path in job.logCandidates {
                let now = fileSize(path)
                if now > (before[path] ?? 0) {
                    watchedLog = path
                    offset = before[path] ?? 0
                    activeLogs[job.label] = path
                    break
                }
            }
        }
        if let path = watchedLog, let chunk = read(path, from: offset), !chunk.isEmpty {
            outputs[job.label, default: ""] += chunk
            offset += UInt64(chunk.utf8.count)
        }

        let live = Agents.states()
        if case .running = live[job.label] ?? .notLoaded { return }

        // One last read: the job may have written its final lines after we last polled.
        if let path = watchedLog, let chunk = read(path, from: offset), !chunk.isEmpty {
            outputs[job.label, default: ""] += chunk
            offset += UInt64(chunk.utf8.count)
        }
        if outputs[job.label, default: ""].isEmpty {
            outputs[job.label] = "(the agent wrote nothing to its log)"
        }
        timer?.invalidate()
        timer = nil
        isRunning = false
        runningLabel = nil
        states = live
    }

    private func modified(_ path: String) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    private func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func read(_ path: String, from: UInt64) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: from)
        guard let data = try? h.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
