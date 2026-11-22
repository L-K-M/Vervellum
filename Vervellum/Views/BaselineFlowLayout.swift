import SwiftUI

/// Keeps the verdict and citation buttons at reading size, sharing a baseline
/// on each line. Each view can wrap within the full proposed width. A fixed
/// item wider than the proposal takes a line of its own at its intrinsic width.
/// SwiftUI mirrors the placements for right-to-left interfaces.
struct BaselineFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        arrange(subviews, width: bounds.width) { subview, origin, size in
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }

    @discardableResult
    private func arrange(_ subviews: Subviews, width: CGFloat,
                         place: ((LayoutSubview, CGPoint, CGSize) -> Void)? = nil) -> CGSize {
        let proposal = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        let dimensions = subviews.map { $0.dimensions(in: proposal) }
        var size = CGSize.zero
        var start = 0
        var lineWidth: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0

        func finishLine(before end: Int) {
            guard end > start else { return }
            if start > 0 { size.height += lineSpacing }
            if let place {
                var x: CGFloat = 0
                for index in start..<end {
                    let item = dimensions[index]
                    let y = size.height + ascent - item[.firstTextBaseline]
                    place(subviews[index], CGPoint(x: x, y: y),
                          CGSize(width: item.width, height: item.height))
                    x += item.width + spacing
                }
            }
            size.width = max(size.width, lineWidth)
            size.height += ascent + descent
            start = end
            lineWidth = 0
            ascent = 0
            descent = 0
        }

        for (index, item) in dimensions.enumerated() {
            if index > start, lineWidth + spacing + item.width > width {
                finishLine(before: index)
            }
            if index > start { lineWidth += spacing }
            lineWidth += item.width
            ascent = max(ascent, item[.firstTextBaseline])
            descent = max(descent, item.height - item[.firstTextBaseline])
        }
        finishLine(before: dimensions.count)
        return size
    }
}
