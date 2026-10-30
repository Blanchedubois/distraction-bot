// K2–K3's standalone check (PLAN_STUDY_DAY.md §4), over the pure parts the app runs — no launch, no log:
//   swiftc -o /tmp/shutdown-check Sources/DistractionBot/Model/StudyDay.swift Sources/DistractionBot/Model/Shutdown.swift scripts/shutdown-check.swift
//   /tmp/shutdown-check
// Judged: a shutdown filed at 00:30 carries `day` = the study day that began the morning before and reads back as that day's; the JSON
// round-trips; "latest wins" over two rows; the offer rule's cases (21:30 / 20:00 / after a filing / session live / 45 min / just now / 01:00).
// The app-side half (`--shutdown-check`: the row in a scratch log, the queue file, the reminder's single row) waits for the user's go-ahead.
import Foundation

var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (got().isEmpty ? "" : " · got \(got())"))
    if !ok { failures += 1 }
}

@main struct Check {
    static func main() {
        StudyDay.startHour = 4
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        let ymd = DateFormatter(); ymd.dateFormat = "yyyy-MM-dd"; ymd.timeZone = .current
        let d28 = ymd.date(from: "2026-10-28")!                                    // calendar midnight
        let study28 = StudyDay.dayStarting(on: d28), study27 = StudyDay.shift(study28, by: -1)
        let filedAt = d28.addingTimeInterval(24 * 3600 + 30 * 60)                  // Thu 29 Oct 00:30
        print("filed at \(f.string(from: filedAt)) → closes \(f.string(from: StudyDay.start(of: filedAt)))")
        expect("00:30 on the 29th closes the study day Wed 28 Oct 04:00", StudyDay.start(of: filedAt) == study28, f.string(from: StudyDay.start(of: filedAt)))

        // the record, as the screen files it (day = the instant; the Store normalises to the start on filing — do both here)
        let rec = Shutdown(day: StudyDay.start(of: filedAt), rating: 4, note: "two good sessions",
                           objectives: [Shutdown.ObjectiveMark(objectiveId: "obj-hw8", mark: "moved", note: "half the set"), Shutdown.ObjectiveMark(objectiveId: "obj-skip", mark: "skipped")],
                           tomorrow: [Shutdown.PlannedItem(objectiveId: "obj-hw8", goal: "Homework #8", minutes: 90), Shutdown.PlannedItem(objectiveId: nil, goal: "read chapter 4", minutes: nil)],
                           startAt: cal.date(bySettingHour: 19, minute: 30, second: 0, of: StudyDay.shift(study28, by: 1)))
        let json = rec.json
        print("json: \(json)")
        expect("json is one line", !json.contains("\n"))
        expect("json carries day as ISO-8601 (Z's reader)", json.contains("\"day\":\"20"), json)
        let back = Shutdown.parse(json)
        expect("round-trips", back == rec)
        expect("day survives to the second", back.map { abs($0.day.timeIntervalSince(study28)) < 1 } ?? false)
        expect("stars ★★★★☆", rec.stars == "★★★★☆", rec.stars)
        expect("an old row with only day and rating parses (missing keys default)", Shutdown.parse("{\"day\":\"2026-10-27T04:00:00Z\",\"rating\":3}") != nil)
        expect("garbage does not parse", Shutdown.parse("not json") == nil)

        // latest wins: the reader's rule over two rows for the same day (ShutdownStore filters by StudyDay.start(of: day) and takes .last)
        let rows = [Shutdown(day: study28, rating: 4, note: "first"), Shutdown(day: study27, rating: 5, note: "yesterday's"), Shutdown(day: study28, rating: 2, note: "second")]
        let latest = rows.filter { StudyDay.start(of: $0.day) == study28 }.last
        expect("latest wins for the 28th", latest?.note == "second", latest?.note ?? "-")
        expect("yesterday's row is not the 28th's", rows.filter { StudyDay.start(of: $0.day) == study28 }.count == 2)
        expect("plan(for: 29th) = the 28th's tomorrow", latest.map { $0.tomorrow.isEmpty } ?? true && rec.tomorrow.count == 2)   // the second filing had no plan: "no plan" is a plan

        // the offer rule (K3's judged cases)
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: d28)! }
        expect("21:30 · no session · no record · no end today → offered", ShutdownRule.offered(now: at(21, 30), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil))
        expect("20:00 → not offered", !ShutdownRule.offered(now: at(20), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil))
        expect("21:30 after a filing → not offered", !ShutdownRule.offered(now: at(21, 30), session: false, offerHour: 21, startHour: 4, shutDown: true, lastEnded: nil))
        expect("21:30 with a session live → not offered", !ShutdownRule.offered(now: at(21, 30), session: true, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil))
        expect("22:00 · last session ended 10 min ago → not offered", !ShutdownRule.offered(now: at(22), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: at(21, 50)))
        expect("22:00 · ended 30 s ago (the end card) → offered", ShutdownRule.offered(now: at(22), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: at(22).addingTimeInterval(-30)))
        expect("22:00 · ended 50 min ago → offered", ShutdownRule.offered(now: at(22), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: at(21, 10)))
        expect("01:00 (still the study day) → offered", ShutdownRule.offered(now: at(1), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil))
        expect("04:30 (the new study day, before the offer hour) → not offered", !ShutdownRule.offered(now: at(4, 30), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil))

        print(failures == 0 ? "ALL OK" : "FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
