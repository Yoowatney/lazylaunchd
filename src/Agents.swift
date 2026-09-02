// Reading launchd agents off disk and asking launchctl about their state.

import Foundation

enum Agents {
    /// Agents belonging to the OS and to installed software, which the user did not
    /// write and has no reason to trigger by hand.
    static let skipPrefixes = ["com.apple.", "com.google.", "homebrew.", "com.github.facebook."]

    /// Normally ~/Library/LaunchAgents. LAZYLAUNCHD_AGENTS_DIR points it somewhere
    /// else, which is how the screenshots are taken against a folder of sample agents
    /// instead of whatever the author happens to have installed.
    static var directory: String {
        if let override = ProcessInfo.processInfo.environment["LAZYLAUNCHD_AGENTS_DIR"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
    }

    static func load() -> [Job] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        var jobs: [Job] = []

        for file in files.sorted() where file.hasSuffix(".plist") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String
            else { continue }
            if skipPrefixes.contains(where: { label.hasPrefix($0) }) { continue }

            var schedule = Schedule.manual
            if let cal = plist["StartCalendarInterval"] as? [String: Any],
               let hour = cal["Hour"] as? Int {
                schedule = .daily(hour: hour, minute: cal["Minute"] as? Int ?? 0)
            } else if let list = plist["StartCalendarInterval"] as? [[String: Any]],
                      let first = list.first, let hour = first["Hour"] as? Int {
                schedule = .daily(hour: hour, minute: first["Minute"] as? Int ?? 0)
            } else if let every = plist["StartInterval"] as? Int {
                schedule = .interval(seconds: every)
            }

            var logs: [String] = []
            for key in ["StandardOutPath", "StandardErrorPath"] {
                guard let p = plist[key] as? String else { continue }
                logs.append(p)
                let dir = (p as NSString).deletingLastPathComponent
                let siblings = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                logs += siblings.filter { $0.hasSuffix(".log") }
                    .map { (dir as NSString).appendingPathComponent($0) }
            }

            jobs.append(Job(label: label, plistPath: path, schedule: schedule,
                            logCandidates: Array(Set(logs)).sorted()))
        }
        return jobs
    }

    /// Parses `launchctl list`: columns are PID, last exit status, label.
    static func states() -> [String: JobState] {
        var out: [String: JobState] = [:]
        for line in run("/bin/launchctl", ["list"]).split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            let label = String(cols[2])
            if cols[0] != "-", Int(cols[0]) != nil {
                out[label] = .running
            } else {
                out[label] = .idle(exit: Int(cols[1]) ?? 0)
            }
        }
        return out
    }
}
