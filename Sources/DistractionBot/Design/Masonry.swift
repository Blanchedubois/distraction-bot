import SwiftUI

/// Pinterest-style columns: each subview goes into the shortest column.
/// Column count follows the available width (3 wide, 2 medium, 1 narrow).
struct Masonry: Layout {
    var spacing: CGFloat = Space.card
    var minColumnWidth: CGFloat = 300

    private func columns(for width: CGFloat) -> Int {
        max(1, min(3, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let cols = columns(for: width)
        let colW = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var heights = Array(repeating: CGFloat(0), count: cols)
        for v in subviews {
            let h = v.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            let i = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            heights[i] += (heights[i] > 0 ? spacing : 0) + h
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = columns(for: bounds.width)
        let colW = (bounds.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var heights = Array(repeating: CGFloat(0), count: cols)
        for v in subviews {
            let h = v.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            let i = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let y = bounds.minY + heights[i] + (heights[i] > 0 ? spacing : 0)
            v.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (colW + spacing), y: y), proposal: ProposedViewSize(width: colW, height: h))
            heights[i] = y - bounds.minY + h
        }
    }
}

/// A self-titled card (Panel) for masonry: title row inside, so it can sit anywhere.
struct Panel<Content: View>: View {
    let title: String
    var note: String? = nil
    var symbol: String? = nil
    var accent: Color? = nil
    var gradient: Bool = false
    var trailing: AnyView? = nil
    @Environment(\.printing) private var printing
    var bare: Bool = false            // content already consists of cards (tiles, goal cards): no outer card
    @ViewBuilder let content: Content
    @Environment(\.narrow) private var narrow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                Text(title).font(Type.title).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                if let note, !narrow { MonoLabel(note).lineLimit(1).layoutPriority(-1) }
                Rectangle().fill(Theme.line).frame(height: 1).frame(minWidth: Space.loose, maxWidth: .infinity).alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + Space.tight }
                if let trailing, !printing { trailing }
            }
            .help(narrow ? (note ?? "") : "")
            .padding(.horizontal, Space.hair)
            .padding(.bottom, Space.stack)
            if bare {
                VStack(alignment: .leading, spacing: Space.stack) { content }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Space.stack) { content }
                    .cardPadding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(accent: accent, watermark: symbol, watermarkSize: 96, gradient: gradient)
            }
        }
    }
}
