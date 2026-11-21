import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

final class BaselineFlowLayoutTests: XCTestCase {
    @MainActor
    func testCitationButtonsWrapAtChipBoundaries() {
        let row = BaselineFlowLayout(spacing: 6, lineSpacing: 4) {
            ForEach(1...5, id: \.self) { number in
                Button("[\(number)]") {}
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 20)
            }
        }
        let host = NSHostingController(rootView: row)
        // Exactly five fit on a wide line, two fit at 66pt, and one at 30pt.
        for (width, height) in [(174, 20), (66, 68), (30, 116)] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 500))
            XCTAssertEqual(size.width, CGFloat(width), accuracy: 0.5)
            XCTAssertEqual(size.height, CGFloat(height), accuracy: 0.5)
        }
    }

    @MainActor
    func testMixedBaselinesMatchTheNativeSingleLineStack() throws {
        // The shorter box extends further below its baseline. Top alignment
        // therefore produces both a different line height and different pixels.
        @ViewBuilder func boxes() -> some View {
            Color.red.frame(width: 30, height: 20)
                .alignmentGuide(.firstTextBaseline) { _ in 5 }
            Color.blue.frame(width: 30, height: 40)
                .alignmentGuide(.firstTextBaseline) { _ in 30 }
        }
        let flow = BaselineFlowLayout(spacing: 6, lineSpacing: 4) { boxes() }
        let stack = HStack(alignment: .firstTextBaseline, spacing: 6) { boxes() }
        let actual = try XCTUnwrap(ImageRenderer(content: flow).cgImage)
        let expected = try XCTUnwrap(ImageRenderer(content: stack).cgImage)
        XCTAssertEqual(actual.height, 45)
        XCTAssertEqual(actual.width, expected.width)
        XCTAssertEqual(actual.height, expected.height)
        // Compare the vertical extent of each box, independent of pixel format
        // and row padding in the two renderer buffers.
        func opaqueRows(_ image: CGImage, at x: Int) -> [Int] {
            let bitmap = NSBitmapImageRep(cgImage: image)
            return (0..<image.height).filter { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.5 }
        }
        for x in [15, 51] {
            XCTAssertEqual(opaqueRows(actual, at: x), opaqueRows(expected, at: x))
        }
    }
}
