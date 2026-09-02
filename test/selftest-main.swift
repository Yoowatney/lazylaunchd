// Driver for test/selftest.sh. Compiled together with the app's non-UI sources, and
// copied to main.swift first because Swift only allows top-level statements there.

import Foundation

let LBL = "com.lazylaunchd.selftest"
let SCRIPT = "/tmp/lazylaunchd-selftest.sh"
let LOG = "/tmp/lazylaunchd-selftest.log"
let PLIST = (Agents.directory as NSString).appendingPathComponent("\(LBL).plist")

func fail(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }

try? "#!/bin/bash\necho hello from selftest\n".write(toFile: SCRIPT, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: SCRIPT)

// 1. create
do {
    try PlistWriter.create(label: LBL, program: SCRIPT, arguments: "",
                           schedule: .daily(hour: 3, minute: 7), logPath: LOG)
} catch { fail("create threw: \(error.localizedDescription)") }
guard FileManager.default.fileExists(atPath: PLIST) else { fail("plist not written") }
print("1. create           OK")

// 2. it parses back with the schedule we asked for
guard let j1 = Agents.load().first(where: { $0.label == LBL }) else { fail("not in load()") }
guard j1.schedule == .daily(hour: 3, minute: 7) else { fail("schedule wrong: \(j1.schedule)") }
print("2. reads back 03:07 OK")

// 3. launchd actually accepted it
let listed = run("/bin/launchctl", ["list"]).stdout.contains(LBL)
print("3. launchd loaded    \(listed ? "OK" : "NOT LOADED")")

// 4. change the schedule
do { try PlistWriter.setSchedule(.interval(seconds: 7200), for: j1, isRunning: false) }
catch { fail("setSchedule threw: \(error.localizedDescription)") }
guard let j2 = Agents.load().first(where: { $0.label == LBL }) else { fail("gone after edit") }
guard j2.schedule == .interval(seconds: 7200) else { fail("edit wrong: \(j2.schedule)") }
print("4. edit -> every 2h  OK")

// 5-8. multiple daily times: launchd allows an array, and reading only the first
// entry used to hide the rest while saving deleted them.
let three: [TimeOfDay] = [.init(hour: 9, minute: 0), .init(hour: 18, minute: 30), .init(hour: 21, minute: 15)]
do { try PlistWriter.setSchedule(.daily(three), for: j1, isRunning: false) }
catch { fail("multi-time setSchedule threw: \(error.localizedDescription)") }

guard let j3 = Agents.load().first(where: { $0.label == LBL }) else { fail("gone after multi-time edit") }
guard j3.schedule.times == three else { fail("expected \(three), read back \(j3.schedule.times)") }
print("5. 3 times survive   OK")

// The file itself should hold an array, not just whatever we happened to keep in memory.
let raw = try! Data(contentsOf: URL(fileURLWithPath: PLIST))
let parsed = try! PropertyListSerialization.propertyList(from: raw, format: nil) as! [String: Any]
guard let arr = parsed["StartCalendarInterval"] as? [[String: Any]], arr.count == 3 else {
    fail("plist did not get a 3-entry StartCalendarInterval array")
}
print("6. written as array  OK")

// Editing one time of a multi-time job must not drop the others.
var kept = three
kept[0] = TimeOfDay(hour: 7, minute: 45)
do { try PlistWriter.setSchedule(.daily(kept), for: j3, isRunning: false) }
catch { fail("edit-one-of-three threw: \(error.localizedDescription)") }
guard let j4 = Agents.load().first(where: { $0.label == LBL }),
      j4.schedule.times == kept.sorted() else { fail("editing one time lost the others") }
print("7. edit keeps others OK")

// Back to one time, which should collapse to a plain dict again.
do { try PlistWriter.setSchedule(.daily(hour: 3, minute: 7), for: j4, isRunning: false) }
catch { fail("back-to-single threw: \(error.localizedDescription)") }
let raw2 = try! Data(contentsOf: URL(fileURLWithPath: PLIST))
let parsed2 = try! PropertyListSerialization.propertyList(from: raw2, format: nil) as! [String: Any]
guard parsed2["StartCalendarInterval"] is [String: Any] else { fail("single time should be a dict") }
print("8. single collapses  OK")

print("9. .bak kept         \(FileManager.default.fileExists(atPath: PLIST + ".bak") ? "OK" : "MISSING")")

// 10. guards
do { try PlistWriter.create(label: LBL, program: SCRIPT, arguments: "", schedule: .manual, logPath: "")
     fail("duplicate label was allowed") } catch {}
do { try PlistWriter.create(label: "nodots", program: SCRIPT, arguments: "", schedule: .manual, logPath: "")
     fail("bad label was allowed") } catch {}
do { try PlistWriter.create(label: "com.x.y", program: "/nope/nope", arguments: "", schedule: .manual, logPath: "")
     fail("missing program was allowed") } catch {}
do { try PlistWriter.setSchedule(.manual, for: j4, isRunning: true)
     fail("edit while running was allowed") } catch {}
print("10. guards            OK")

// 11. delete - guarded while running, then for real
do { try PlistWriter.remove(j4, isRunning: true); fail("delete while running was allowed") } catch {}
do { try PlistWriter.remove(j4, isRunning: false) }
catch { fail("remove threw: \(error.localizedDescription)") }
guard !FileManager.default.fileExists(atPath: PLIST) else { fail("plist still there after delete") }
guard !run("/bin/launchctl", ["list"]).stdout.contains(LBL) else { fail("still loaded after delete") }
guard Agents.load().first(where: { $0.label == LBL }) == nil else { fail("still listed after delete") }
print("11. delete            OK")

// Recoverable is the whole point of trashing rather than unlinking.
let trash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
let trashed = ((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [])
    .contains { $0.hasPrefix("\(LBL).plist") }
print("12. recoverable       \(trashed ? "OK (in Trash)" : "NOT IN TRASH")")

// 13. a bootstrap that does not take must be reported. This is the case that used to
// pass in silence: bootout succeeds, bootstrap does not, and the agent is left
// unloaded while the app tells the user the save went through. Pointing reload at a
// plist that is not there is the cheapest way to make launchd refuse, and it creates
// nothing to clean up afterwards.
let ghost = "com.lazylaunchd.selftest.missing"
let ghostPlist = (Agents.directory as NSString).appendingPathComponent("\(ghost).plist")
guard !FileManager.default.fileExists(atPath: ghostPlist) else { fail("\(ghostPlist) exists - pick another label") }
let refused = PlistWriter.reload(label: ghost, plistPath: ghostPlist)
guard !refused.ok else { fail("bootstrap of a missing plist reported success") }
guard !refused.message.isEmpty else { fail("bootstrap failed without saying why") }
print("13. failure surfaces OK (\(refused.message.split(separator: "\n").first ?? ""))")


// 14. an agent launchd starts for a non-clock reason must say so. Calling a WatchPaths
// agent "manual" told people it only ran when they pressed Run, while it was in fact
// waking on every file change - one had been doing that and dying for months.
let trig = "com.lazylaunchd.selftest.trigger"
let trigPlist = (Agents.directory as NSString).appendingPathComponent("\(trig).plist")
guard !FileManager.default.fileExists(atPath: trigPlist) else { fail("\(trigPlist) exists") }
try! PropertyListSerialization.data(
    fromPropertyList: ["Label": trig,
                       "ProgramArguments": ["/bin/echo", "hi"],
                       "WatchPaths": ["/tmp"]] as [String: Any],
    format: .xml, options: 0).write(to: URL(fileURLWithPath: trigPlist))

guard let tj = Agents.load().first(where: { $0.label == trig }) else { fail("trigger agent not listed") }
guard tj.schedule == .trigger("on file change") else {
    fail("WatchPaths agent read as \(tj.schedule) instead of a trigger")
}
guard !tj.schedule.isEditable else { fail("a trigger agent should not be editable") }
print("14. trigger honest   OK (\(tj.schedule.fullLabel))")

// Editing one would clear the clock keys and leave WatchPaths, so the app would start
// calling it something it is not. It has to refuse.
do {
    try PlistWriter.setSchedule(.daily(hour: 5, minute: 0), for: tj, isRunning: false)
    fail("setSchedule accepted a WatchPaths agent")
} catch {}
print("15. refuses to edit  OK")
try? FileManager.default.removeItem(atPath: trigPlist)

// cleanup
for p in [SCRIPT, LOG] { try? FileManager.default.removeItem(atPath: p) }
for f in ((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [])
    where f.hasPrefix("\(LBL).plist") {
    try? FileManager.default.removeItem(atPath: (trash as NSString).appendingPathComponent(f))
}
print("cleanup              OK")
print("\nALL PASS")
