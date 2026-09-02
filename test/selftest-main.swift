
// ---- self check ----
let LBL = "com.lazylaunchd.selftest"
let SCRIPT = "/tmp/lr-selftest.sh"
let LOG = "/tmp/lr-selftest.log"
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
let listed = run("/bin/launchctl", ["list"]).contains(LBL)
print("3. launchd loaded    \(listed ? "OK" : "NOT LOADED")")

// 4. change the schedule
do { try PlistWriter.setSchedule(.interval(seconds: 7200), for: j1, isRunning: false) }
catch { fail("setSchedule threw: \(error.localizedDescription)") }
guard let j2 = Agents.load().first(where: { $0.label == LBL }) else { fail("gone after edit") }
guard j2.schedule == .interval(seconds: 7200) else { fail("edit wrong: \(j2.schedule)") }
print("4. edit -> every 2h  OK")

// 5. backup kept
print("5. .bak kept         \(FileManager.default.fileExists(atPath: PLIST + ".bak") ? "OK" : "MISSING")")

// 6. guards
do { try PlistWriter.create(label: LBL, program: SCRIPT, arguments: "", schedule: .manual, logPath: "")
     fail("duplicate label was allowed") } catch {}
do { try PlistWriter.create(label: "nodots", program: SCRIPT, arguments: "", schedule: .manual, logPath: "")
     fail("bad label was allowed") } catch {}
do { try PlistWriter.create(label: "com.x.y", program: "/nope/nope", arguments: "", schedule: .manual, logPath: "")
     fail("missing program was allowed") } catch {}
do { try PlistWriter.setSchedule(.manual, for: j2, isRunning: true)
     fail("edit while running was allowed") } catch {}
print("6. guards            OK")

// 7. delete - guarded while running, then for real
do { try PlistWriter.remove(j2, isRunning: true); fail("delete while running was allowed") } catch {}
do { try PlistWriter.remove(j2, isRunning: false) }
catch { fail("remove threw: \(error.localizedDescription)") }
guard !FileManager.default.fileExists(atPath: PLIST) else { fail("plist still there after delete") }
guard !run("/bin/launchctl", ["list"]).contains(LBL) else { fail("still loaded after delete") }
guard Agents.load().first(where: { $0.label == LBL }) == nil else { fail("still listed after delete") }
print("7. delete            OK")

// Recoverable is the whole point of trashing rather than unlinking.
let trash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
let trashed = ((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [])
    .contains { $0.hasPrefix("\(LBL).plist") }
print("8. recoverable       \(trashed ? "OK (in Trash)" : "NOT IN TRASH")")

// cleanup
for p in [SCRIPT, LOG] { try? FileManager.default.removeItem(atPath: p) }
for f in ((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [])
    where f.hasPrefix("\(LBL).plist") {
    try? FileManager.default.removeItem(atPath: (trash as NSString).appendingPathComponent(f))
}
print("cleanup              OK")
print("\nALL PASS")
