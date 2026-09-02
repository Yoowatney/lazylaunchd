// The only part of the app that changes state outside itself: writing, reloading
// and removing agents. test/selftest.sh exercises all of it against real launchd.

import Foundation

enum PlistError: LocalizedError {
    case running, badLabel, duplicate, noProgram, write(String)

    var errorDescription: String? {
        switch self {
        case .running:    return "This agent is running right now. Wait for it to finish."
        case .badLabel:   return "A label needs at least one dot, e.g. com.you.backup."
        case .duplicate:  return "An agent with that label already exists."
        case .noProgram:  return "Pick a script or binary that exists and is executable."
        case .write(let m): return m
        }
    }
}

enum PlistWriter {
    static var uid: String { String(getuid()) }

    private static func apply(_ schedule: Schedule, to dict: inout [String: Any]) {
        dict["StartCalendarInterval"] = nil
        dict["StartInterval"] = nil
        switch schedule {
        case .daily(let times):
            // One time stays a plain dict, matching how these files are usually
            // written by hand; several become the array launchd also accepts. Writing
            // a single dict for a multi-time job used to delete every time but one.
            let entries = times.sorted().map { ["Hour": $0.hour, "Minute": $0.minute] }
            dict["StartCalendarInterval"] = entries.count == 1 ? entries[0] : entries
        case .interval(let s):
            dict["StartInterval"] = s
        case .manual:
            break
        }
    }

    /// Writes via a temp file and a single replace, so a crash mid-write cannot leave
    /// launchd reading a truncated plist. The previous version is kept as .bak.
    private static func save(_ dict: [String: Any], to path: String) throws {
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            throw PlistError.write("Could not serialise the plist: \(error.localizedDescription)")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path + ".bak")
            try? fm.copyItem(atPath: path, toPath: path + ".bak")
        }
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            _ = try fm.replaceItemAt(URL(fileURLWithPath: path),
                                     withItemAt: URL(fileURLWithPath: tmp))
        } catch {
            try? fm.removeItem(atPath: tmp)
            throw PlistError.write("Could not write \(path): \(error.localizedDescription)")
        }
    }

    /// bootout then bootstrap - launchd reads the plist once at load, so a schedule
    /// change does nothing until the job is re-registered.
    static func reload(label: String, plistPath: String) {
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
    }

    static func setSchedule(_ schedule: Schedule, for job: Job, isRunning: Bool) throws {
        if isRunning { throw PlistError.running }
        guard let data = FileManager.default.contents(atPath: job.plistPath),
              var dict = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else { throw PlistError.write("Could not read \(job.plistPath).") }

        apply(schedule, to: &dict)
        try save(dict, to: job.plistPath)
        reload(label: job.label, plistPath: job.plistPath)
    }

    /// Unloads the agent and puts its plist in the Trash. Trash rather than unlink:
    /// deleting is the one action here with nothing to undo it, and macOS already
    /// ships the undo.
    static func remove(_ job: Job, isRunning: Bool) throws {
        if isRunning { throw PlistError.running }
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(job.label)"])
        let fm = FileManager.default
        for path in [job.plistPath, job.plistPath + ".bak"] where fm.fileExists(atPath: path) {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                throw PlistError.write("Unloaded it, but could not move \(path) to the Trash: \(error.localizedDescription)")
            }
        }
    }

    static func create(label: String, program: String, arguments: String,
                       schedule: Schedule, logPath: String) throws {
        guard label.contains("."), !label.hasPrefix("."), !label.hasSuffix(".") else {
            throw PlistError.badLabel
        }
        let path = (Agents.directory as NSString).appendingPathComponent("\(label).plist")
        if FileManager.default.fileExists(atPath: path) { throw PlistError.duplicate }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: program, isDirectory: &isDir),
              !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: program)
        else { throw PlistError.noProgram }

        // ProgramArguments rather than Program: launchd passes no shell, so extra
        // arguments have to be separate array entries.
        var argv = [program]
        argv += arguments.split(separator: " ").map(String.init)

        var dict: [String: Any] = ["Label": label, "ProgramArguments": argv]
        apply(schedule, to: &dict)
        if !logPath.isEmpty {
            dict["StandardOutPath"] = logPath
            dict["StandardErrorPath"] = logPath
        }
        try save(dict, to: path)
        reload(label: label, plistPath: path)
    }
}
