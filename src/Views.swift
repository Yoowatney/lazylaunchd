// The pieces the main screen is assembled from.

import SwiftUI

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
        .contentShape(Rectangle())
        // The row is too narrow to list several times, so it shows the first and a
        // count. Hovering anywhere on the row gives the rest; selecting the agent
        // spells them out in full in the detail pane.
        .help(job.schedule.isAbbreviated ? job.schedule.fullLabel : "")
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
    /// Only the end of the file is read in, and saying so beats letting someone scroll
    /// to the top and take the first line they see for the beginning of the log.
    var truncated: Bool = false

    /// SwiftUI lays a Text out as a single run, and textSelection makes that worse, so
    /// handing it the whole 128 KB read from a long-running agent's log froze the
    /// window for seconds on selection. Reading was never the cost — that measured at
    /// 3 ms — so the fix is to render a page at a time rather than to read less.
    private static let pageLines = 300

    @State private var visible = LogPane.pageLines

    private var lines: [String] {
        // Trailing newline would otherwise show as a blank last line.
        text.hasSuffix("\n")
            ? text.dropLast().components(separatedBy: "\n")
            : text.components(separatedBy: "\n")
    }

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
                if truncated {
                    Text("· end of log")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
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
                    let all = lines
                    let hidden = max(0, all.count - visible)
                    VStack(alignment: .leading, spacing: 0) {
                        if hidden > 0 {
                            Button {
                                visible += LogPane.pageLines
                            } label: {
                                Text("Load \(min(hidden, LogPane.pageLines)) earlier lines  ·  \(hidden) above")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .padding(.bottom, 8)
                        } else if truncated {
                            Text("Start of what was read in — the file continues above.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                        }

                        Text(text.isEmpty ? "Pick an agent and press Run."
                                          : all.suffix(visible).joined(separator: "\n"))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .id("end")
                }
                // The single-parameter onChange is deprecated on macOS 14 but is the
                // only form Ventura has, and it is all this needs.
                .onChange(of: text) { _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        // AppKit's semantic colours rather than SwiftUI's .background.secondary and
        // .separator, which both arrived in macOS 14. These adapt to dark mode just
        // the same.
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Schedule picker shared by the edit sheet and the new-agent sheet.
