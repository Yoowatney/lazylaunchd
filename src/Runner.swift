// Starts an agent and follows whatever it writes to its log.

import SwiftUI
import Foundation

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

    func refresh() {
        jobs = Agents.load()
        states = Agents.states()
    }

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
        outputs[job.label] = ""
        activeLogs[job.label] = nil
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
