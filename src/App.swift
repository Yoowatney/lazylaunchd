// The detail pane, the split view holding it, and the entry point.

import SwiftUI
import AppKit

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

/// Hand-rolled rather than ContentUnavailableView, which needs macOS 14. This is the
/// only thing that stood between the app and running on Ventura.
struct EmptySelection: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No agent selected")
                .font(.system(size: 15, weight: .semibold))
            Text("Pick an agent on the left to run it now.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                EmptySelection()
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
