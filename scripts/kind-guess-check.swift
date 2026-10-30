// N1's check (PLAN_NEW_OBJECTIVE_WIDGET.md §4): the kind guess table of §3.4 plus the real titles, and every symbol in the
// table present in this Mac's SF Symbol catalogue (the same plist `Symbols.all` reads). No app launch, nothing written.
//   swiftc -o /tmp/kind-guess-check Sources/DistractionBot/Model/KindGuess.swift scripts/kind-guess-check.swift && /tmp/kind-guess-check
import Foundation

@main struct Check {
    static func main() {
        let cases: [(String, String?)] = [
            ("Homework #9", "homework"), ("HW 3", "homework"), ("Assignment 2 (vectors)", "homework"),
            ("problem set 4", "problem set"), ("PSet 7", "problem set"), ("Exercises 1–6", "problem set"),
            ("Read chapter 12", "reading"), ("Paper on membranes", "reading"), ("Ch. 4 notes", "reading"),
            ("Midterm review", "review"), ("Final exam", "review"), ("Quiz 2", "review"),
            ("Research Proposal Presentation", "presentation"),   // the real one: the head noun, last in the title, wins over "research" and "proposal"
            ("research proposal draft", "write-up"),
            ("Essay on Kant", "write-up"), ("Lab report 3", "write-up"), ("Thesis outline", "write-up"),
            ("Slides for Thursday", "presentation"), ("Poster session", "presentation"),
            ("random-walk simulation", "coding"), ("Implement the MSD plot", "coding"), ("Debug the parser", "coding"),
            ("Lit review", "research"), ("Find sources", "research"),
            ("Rewrite the intro", "revision"), ("Address feedback", "revision"),
            ("Thread safety notes", nil), ("Show and tell", nil), ("Meeting", nil), ("", nil),
        ]
        var failed = 0
        for (title, want) in cases {
            let got = KindGuess.guess(title)
            let ok = got == want
            if !ok { failed += 1 }
            print("\(ok ? "ok  " : "FAIL") \(title.padding(toLength: 34, withPad: " ", startingAt: 0)) → \(got ?? "—")\(ok ? "" : "  (wanted \(want ?? "—"))")")
        }
        // Every symbol in the table exists on this Mac.
        let plist = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_order.plist"
        if let all = NSArray(contentsOfFile: plist) as? [String], !all.isEmpty {
            let set = Set(all)
            for r in KindGuess.rules {
                let ok = set.contains(r.symbol)
                if !ok { failed += 1 }
                print("\(ok ? "ok  " : "FAIL") symbol \(r.symbol) for \(r.kind)")
            }
        } else { print("skip  symbol catalogue not readable at \(plist)") }
        print(failed == 0 ? "all passed" : "\(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
