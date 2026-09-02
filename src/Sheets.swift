// Editing a schedule and creating an agent, both of which write plists.

import SwiftUI
import AppKit

struct ScheduleForm: View {
    @Binding var kind: Int          // 0 daily, 1 interval, 2 manual
    /// A list, because launchd allows several daily times and a job that runs morning,
    /// evening and night is ordinary. Editing used to offer one field and silently
    /// drop the others on save.
    @Binding var times: [Date]
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(times.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        DatePicker("", selection: $times[i], displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                            .labelsHidden()
                        Button {
                            times.remove(at: i)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(times.count <= 1)   // a daily job needs a time
                        .help("Remove this time")
                    }
                }
                Button {
                    times.append(times.last.map { $0.addingTimeInterval(3600) } ?? Date())
                } label: {
                    Label("Add a time", systemImage: "plus").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
        case 1:
            Stepper("Every \(everyHours) hour\(everyHours == 1 ? "" : "s")",
                    value: $everyHours, in: 1...24)
        default:
            Text("Only runs when you press Run, or when something calls launchctl start.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    static func schedule(kind: Int, times: [Date], everyHours: Int) -> Schedule {
        switch kind {
        case 0:
            let cal = Calendar.current
            let parsed = times.map { d -> TimeOfDay in
                let c = cal.dateComponents([.hour, .minute], from: d)
                return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }
            // Two pickers can land on the same time; launchd would just fire twice.
            return .daily(Array(Set(parsed)).sorted())
        case 1:
            return .interval(seconds: everyHours * 3600)
        default:
            return .manual
        }
    }

    static func dates(from times: [TimeOfDay]) -> [Date] {
        let cal = Calendar.current
        return times.sorted().compactMap {
            cal.date(from: DateComponents(hour: $0.hour, minute: $0.minute))
        }
    }
}

struct EditScheduleSheet: View {
    let job: Job
    let isRunning: Bool
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = 0
    @State private var times: [Date] = [Date()]
    @State private var everyHours = 1
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule").font(.system(size: 15, weight: .semibold))
            Text(job.label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Form { ScheduleForm(kind: $kind, times: $times, everyHours: $everyHours) }
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
        case .daily(let t):
            kind = 0
            times = ScheduleForm.dates(from: t)
            if times.isEmpty { times = [Date()] }
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
                ScheduleForm.schedule(kind: kind, times: times, everyHours: everyHours),
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
    @State private var times: [Date] = [Date()]
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
                ScheduleForm(kind: $kind, times: $times, everyHours: $everyHours)
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
                schedule: ScheduleForm.schedule(kind: kind, times: times, everyHours: everyHours),
                logPath: logPath.trimmingCharacters(in: .whitespaces))
            onCreated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
