// Starts an agent and follows whatever it writes to its log.

import SwiftUI
import Foundation

final class Runner: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var states: [String: JobState] = [:]
    @Published var output: String = ""
    @Published var isRunning = false
    @Published var activeLog: String?

    private var offset: UInt64 = 0
    private var watchedLog: String?
    private var timer: Timer?
    private var runningLabel: String?

    func refresh() {
        jobs = Agents.load()
        states = Agents.states()
    }

    func state(for job: Job) -> JobState {
        if isRunning, runningLabel == job.label { return .running }
        return states[job.label] ?? .notLoaded
    }

    func start(_ job: Job) {
        guard !isRunning else { return }
        output = ""
        activeLog = nil
        isRunning = true
        runningLabel = job.label

        // Snapshot every candidate so we can tell which file this run writes to.
        let sizes = job.logCandidates.reduce(into: [String: UInt64]()) { acc, path in
            acc[path] = fileSize(path)
        }

        let err = run("/bin/launchctl", ["start", job.label])
        if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = err
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
                    activeLog = path
                    break
                }
            }
        }
        if let path = watchedLog, let chunk = read(path, from: offset), !chunk.isEmpty {
            output += chunk
            offset += UInt64(chunk.utf8.count)
        }

        let live = Agents.states()
        if case .running = live[job.label] ?? .notLoaded { return }

        // One last read: the job may have written its final lines after we last polled.
        if let path = watchedLog, let chunk = read(path, from: offset), !chunk.isEmpty {
            output += chunk
            offset += UInt64(chunk.utf8.count)
        }
        if output.isEmpty { output = "(the agent wrote nothing to its log)" }
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
