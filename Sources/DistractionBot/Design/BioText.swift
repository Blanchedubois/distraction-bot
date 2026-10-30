import SwiftUI

// PLAN_OBJECTIVES_TAB §5a Q10–Q11: a subject's or objective's bio takes markdown and shows collapsed to a few sentences.

/// A light block parser: SwiftUI's single-`Text` markdown drops paragraph breaks, so the bio is split into blocks first and
/// each block is one `Text` with inline markdown (bold, italic, code, links).
enum BioMarkdown {
    enum Block: Equatable { case heading(String), paragraph(String), bullets([String]) }

    static func blocks(_ text: String) -> [Block] {
        let chunks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [Block] = []
        for chunk in chunks {
            let lines = chunk.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("• ") }) {
                out.append(.bullets(lines.map { String($0.dropFirst(2)) }))
            } else if lines.count == 1, let h = lines.first, h.hasPrefix("#") {
                out.append(.heading(h.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else {
                // single newlines inside a paragraph are soft breaks; a run of bullet lines after prose is split off
                var prose: [String] = [], bullets: [String] = []
                func flush() { if !prose.isEmpty { out.append(.paragraph(prose.joined(separator: " "))); prose = [] }; if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] } }
                for l in lines {
                    if l.hasPrefix("#") { flush(); out.append(.heading(l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))) }
                    else if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") { bullets.append(String(l.dropFirst(2))) }
                    else { if !bullets.isEmpty { flush() }; prose.append(l) }
                }
                flush()
            }
        }
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// The collapsed form (§5a Q11): the first paragraph's first two sentences, plain prose from a heading or a list if that comes first.
    static func summary(_ text: String) -> String {
        let first: String = {
            for b in blocks(text) {
                switch b { case .paragraph(let p): return p; case .heading(let h): return h; case .bullets(let items): return items.joined(separator: " · ") }
            }
            return text
        }()
        let sentences = first.components(separatedBy: ". ").filter { !$0.isEmpty }
        guard sentences.count > 2 else { return first }
        return sentences.prefix(2).joined(separator: ". ") + "."
    }

    /// Whether collapsing hides anything: more than one block, or more than two sentences in the first.
    static func isLong(_ text: String) -> Bool {
        let bs = blocks(text)
        if bs.count > 1 { return true }
        return summary(text) != (bs.first.map { b -> String in switch b { case .paragraph(let p): return p; case .heading(let h): return h; case .bullets(let i): return i.joined(separator: " · ") } } ?? text)
    }
}

/// A bio: markdown, collapsed to a few sentences with a `more` pill (§5a Q10–Q11).
struct BioText: View {
    let text: String
    var font: Font = Type.body
    var color: Color = Theme.ink2
    var lines: Int = 3                      // collapsed line limit
    var collapsible = true
    var accent: Color = Theme.accent
    /// PLAN_SUBJECT_PROGRESS S2: also collapse a short bio past this many characters (a card's two-sentence bio still ran eight lines);
    /// the collapsed form is then cut at `lines` with the same `more` pill. nil: only `isLong` collapses.
    var longAfter: Int? = nil
    @State private var expanded = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_BIO"] == "expanded"

    var body: some View {
        let long = collapsible && (BioMarkdown.isLong(text) || longAfter.map { BioMarkdown.summary(text).count > $0 } == true)
        VStack(alignment: .leading, spacing: Space.stack) {
            if long && !expanded {
                Text(BioMarkdown.inline(BioMarkdown.summary(text))).font(font).foregroundStyle(color).lineSpacing(Space.hair).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(BioMarkdown.blocks(text).enumerated()), id: \.offset) { _, b in
                    switch b {
                    case .heading(let h): Text(BioMarkdown.inline(h)).font(Type.strong).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    case .paragraph(let p): Text(BioMarkdown.inline(p)).font(font).foregroundStyle(color).lineSpacing(Space.hair).fixedSize(horizontal: false, vertical: true)
                    case .bullets(let items):
                        VStack(alignment: .leading, spacing: Space.hair) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                                HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                                    Text("•").font(font).foregroundStyle(Theme.muted)
                                    Text(BioMarkdown.inline(i)).font(font).foregroundStyle(color).lineSpacing(Space.hair).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            if long { PillButton(text: expanded ? "less" : "more", kind: .accent, accent: accent) { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }
        }
        .tint(accent)
    }
}
