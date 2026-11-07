import SwiftUI

/// Wraps its children left to right onto new lines: chips, a routine's steps.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.unit
    /// The gap between lines; the item spacing when not set.
    var lineSpacing: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + (lineSpacing ?? spacing) * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = [([], 0, 0)]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + s.width > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(([], 0, 0))
            }
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += s.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
        }
        return rows
    }
}

extension View {
    /// The one content-card surface: glass fill, card corners and the shared hairline edge.
    /// (Status notices keep their own tone treatment.)
    func cardSurface() -> some View {
        background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Ink.glassStroke, lineWidth: Radius.hairlineWidth))
    }
}
