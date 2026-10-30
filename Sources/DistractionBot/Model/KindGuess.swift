import Foundation

/// PLAN_NEW_OBJECTIVE_WIDGET N1 (§3.4): the kind of an objective guessed from its title, and the SF Symbol each kind wears.
/// Foundation only, so `scripts/kind-guess-check.swift` can compile it alone. Kinds are `SessionKind` raw values.
enum KindGuess {
    /// A phrase matches on word boundaries, case-insensitively, so "read" does not fire inside "thread" and "hw" not inside "show".
    /// Symbols are the names in this Mac's catalogue (macOS 26: `text.document`, not the `doc.text` alias), checked by the script.
    static let rules: [(phrases: [String], kind: String, symbol: String)] = [
        (["homework", "hw", "assignment"],                                     "homework",     "pencil.and.list.clipboard"),
        (["problem set", "pset", "exercises", "problems"],                     "problem set",  "function"),
        (["reading", "read", "chapter", "ch.", "paper"],                       "reading",      "book"),
        (["exam", "midterm", "final", "quiz", "review", "revise for"],         "review",       "checklist"),
        (["essay", "report", "proposal", "draft", "write-up", "write", "thesis"], "write-up",  "text.document"),
        (["presentation", "slides", "talk", "poster"],                         "presentation", "rectangle.on.rectangle.angled"),
        (["coding", "code", "implement", "simulation", "script", "debug"],     "coding",       "chevron.left.forwardslash.chevron.right"),
        (["research", "sources", "literature", "lit review"],                  "research",     "magnifyingglass"),
        (["revise", "rewrite", "edit", "feedback"],                            "revision",     "arrow.trianglehead.2.clockwise"),
    ]

    /// The symbol a kind wears (the rule's symbol; `other` and unknown kinds get nil, so the subject's icon stands in).
    static func symbol(for kind: String) -> String? { rules.first { $0.kind == kind }?.symbol }

    /// The guessed kind's raw value, or nil when nothing in the title says. Among the phrases found, the longest wins
    /// ("lit review" over "review"), then the one latest in the title: English puts the head noun last, so
    /// "Research Proposal Presentation" is a presentation and "research proposal draft" a write-up.
    static func guess(_ title: String) -> String? {
        let t = " " + title.lowercased().replacingOccurrences(of: "[^a-z0-9.\\-]+", with: " ", options: .regularExpression) + " "
        var best: (kind: String, length: Int, at: Int)? = nil
        for r in rules {
            for p in r.phrases {
                for form in [" " + p + " ", " " + p + ". "] {
                    guard let range = t.range(of: form, options: .backwards) else { continue }
                    let at = t.distance(from: t.startIndex, to: range.lowerBound)
                    if best == nil || p.count > best!.length || (p.count == best!.length && at > best!.at) { best = (r.kind, p.count, at) }
                }
            }
        }
        return best?.kind
    }
}
