// lazylaunchd - a small macOS app to run your own launchd agents by hand.
//
// launchd is good at running things on a schedule and bad at letting you run one
// right now and watch what it did. This lists the agents in ~/Library/LaunchAgents,
// runs the one you pick, and streams whatever that job writes to its log.
//
// Single file on purpose: `swiftc LazyLaunchd.swift` is the whole build.

import SwiftUI
import AppKit

// MARK: - Model

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

// MARK: - Loading agents

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

// MARK: - Writing agents

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
        case .daily(let h, let m): dict["StartCalendarInterval"] = ["Hour": h, "Minute": m]
        case .interval(let s):     dict["StartInterval"] = s
        case .manual:              break
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

// MARK: - Runner

@MainActor
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

// MARK: - Views

struct StatusDot: View {
    let state: JobState
    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.black.opacity(0.08)))
    }
}

struct JobRow: View {
    let job: Job
    let state: JobState

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.shortName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(job.schedule.label)
                    if case .idle(let e) = state, e != 0 {
                        Text("· exit \(e)").foregroundStyle(.orange)
                    }
                    if case .notLoaded = state {
                        Text("· not loaded").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct LogPane: View {
    let text: String
    let isRunning: Bool
    let path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("OUTPUT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text("live").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let path {
                    Button {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    } label: {
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "Pick an agent and press Run." : text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("end")
                }
                .onChange(of: text) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// Schedule picker shared by the edit sheet and the new-agent sheet.
struct ScheduleForm: View {
    @Binding var kind: Int          // 0 daily, 1 interval, 2 manual
    @Binding var time: Date
    @Binding var everyHours: Int

    var body: some View {
        Picker("Runs", selection: $kind) {
            Text("Daily").tag(0)
            Text("Every N hours").tag(1)
            Text("Manual only").tag(2)
        }
        .pickerStyle(.segmented)

        switch kind {
        case 0:
            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
        case 1:
            Stepper("Every \(everyHours) hour\(everyHours == 1 ? "" : "s")",
                    value: $everyHours, in: 1...24)
        default:
            Text("Only runs when you press Run, or when something calls launchctl start.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    static func schedule(kind: Int, time: Date, everyHours: Int) -> Schedule {
        switch kind {
        case 0:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .daily(hour: c.hour ?? 0, minute: c.minute ?? 0)
        case 1:
            return .interval(seconds: everyHours * 3600)
        default:
            return .manual
        }
    }
}

struct EditScheduleSheet: View {
    let job: Job
    let isRunning: Bool
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = 0
    @State private var time = Date()
    @State private var everyHours = 1
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule").font(.system(size: 15, weight: .semibold))
            Text(job.label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Form { ScheduleForm(kind: $kind, time: $time, everyHours: $everyHours) }
                .formStyle(.columns)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Saving rewrites the plist (keeping a .bak) and reloads the agent.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { load() }
    }

    private func load() {
        switch job.schedule {
        case .daily(let h, let m):
            kind = 0
            time = Calendar.current.date(from: DateComponents(hour: h, minute: m)) ?? Date()
        case .interval(let s):
            kind = 1
            everyHours = max(1, s / 3600)
        case .manual:
            kind = 2
        }
    }

    private func save() {
        do {
            try PlistWriter.setSchedule(
                ScheduleForm.schedule(kind: kind, time: time, everyHours: everyHours),
                for: job, isRunning: isRunning)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct NewAgentSheet: View {
    var onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var program = ""
    @State private var arguments = ""
    @State private var logPath = ""
    @State private var kind = 0
    @State private var time = Date()
    @State private var everyHours = 1
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New agent").font(.system(size: 15, weight: .semibold))

            Form {
                TextField("Label", text: $label, prompt: Text("com.you.backup"))
                HStack(spacing: 6) {
                    TextField("Script", text: $program, prompt: Text("/path/to/script.sh"))
                    Button("Choose…") { choose() }
                }
                TextField("Arguments", text: $arguments, prompt: Text("optional"))
                TextField("Log file", text: $logPath, prompt: Text("optional"))
                Divider()
                ScheduleForm(kind: $kind, time: $time, everyHours: $everyHours)
            }
            .formStyle(.columns)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Writes ~/Library/LaunchAgents/<label>.plist and loads it. The script must be executable (chmod +x).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(label.isEmpty || program.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { program = url.path }
    }

    private func create() {
        do {
            try PlistWriter.create(
                label: label.trimmingCharacters(in: .whitespaces),
                program: program, arguments: arguments,
                schedule: ScheduleForm.schedule(kind: kind, time: time, everyHours: everyHours),
                logPath: logPath.trimmingCharacters(in: .whitespaces))
            onCreated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DetailView: View {
    let job: Job
    @ObservedObject var runner: Runner
    var onDeleted: () -> Void = {}
    @State private var editingSchedule = false
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private func delete() {
        do {
            try PlistWriter.remove(job, isRunning: runner.isRunning)
            runner.refresh()
            onDeleted()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private var nextRunText: String? {
        guard let next = job.schedule.nextFire else { return nil }
        let mins = Int(next.timeIntervalSinceNow / 60)
        if mins < 60 { return "next run in \(max(mins, 0))m" }
        return "next run in \(mins / 60)h \(mins % 60)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.shortName).font(.system(size: 20, weight: .semibold))
                Text(job.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 6) {
                Chip(icon: "clock", text: job.schedule.label)
                switch runner.state(for: job) {
                case .idle(let e) where e == 0:
                    Chip(icon: "checkmark.circle.fill", text: "last exit 0", tint: .green)
                case .idle(let e):
                    Chip(icon: "exclamationmark.triangle.fill", text: "last exit \(e)", tint: .orange)
                case .running:
                    Chip(icon: "play.circle.fill", text: "running", tint: .accentColor)
                case .notLoaded:
                    Chip(icon: "moon.zzz.fill", text: "not loaded")
                }
                if let nextRunText {
                    Chip(icon: "arrow.right.circle", text: nextRunText)
                }
            }

            HStack(spacing: 10) {
                Button {
                    runner.start(job)
                } label: {
                    Label(runner.isRunning ? "Running…" : "Run", systemImage: "play.fill")
                        .frame(minWidth: 62)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(runner.isRunning)

                Button {
                    editingSchedule = true
                } label: {
                    Label("Schedule", systemImage: "calendar.badge.clock")
                }
                .controlSize(.large)
                .disabled(runner.isRunning)

                Button("Reveal plist") {
                    NSWorkspace.shared.selectFile(job.plistPath, inFileViewerRootedAtPath: "")
                }
                .controlSize(.large)

                Spacer()

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.large)
                .disabled(runner.isRunning)
                .help("Unload and move the plist to the Trash")
            }
            .sheet(isPresented: $editingSchedule) {
                EditScheduleSheet(job: job,
                                  isRunning: runner.isRunning,
                                  onSaved: { runner.refresh() })
            }
            .confirmationDialog("Delete \(job.shortName)?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The agent is unloaded and its plist goes to the Trash, so you can put it back from Finder. Anything the agent itself created is left alone.")
            }
            .alert("Could not delete", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }

            LogPane(text: runner.output, isRunning: runner.isRunning, path: runner.activeLog)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var selection: Job?
    @State private var creating = false

    var body: some View {
        NavigationSplitView {
            List(runner.jobs, selection: $selection) { job in
                JobRow(job: job, state: runner.state(for: job)).tag(job)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 330)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { creating = true } label: {
                        Label("New agent", systemImage: "plus")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    Spacer()
                }
                .background(.bar)
            }
            .toolbar {
                ToolbarItem {
                    Button { runner.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    // "Refresh", not "Reload": in launchd terms reloading is
                    // bootout + bootstrap, which is what saving a schedule does.
                    // This only re-reads the folder.
                    .help("Refresh the list")
                }
            }
            .sheet(isPresented: $creating) {
                NewAgentSheet(onCreated: {
                    runner.refresh()
                    selection = runner.jobs.first
                })
            }
        } detail: {
            if let selection {
                DetailView(job: selection, runner: runner,
                           onDeleted: { self.selection = runner.jobs.first })
                    .id(selection.label)
            } else {
                ContentUnavailableView(
                    "No agent selected",
                    systemImage: "clock.badge.checkmark",
                    description: Text("Pick an agent on the left to run it now."))
            }
        }
        .navigationTitle("lazylaunchd")
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            runner.refresh()
            if selection == nil { selection = runner.jobs.first }
        }
    }
}

@main
struct LazyLaunchdApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
