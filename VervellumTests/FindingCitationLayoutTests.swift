import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

@MainActor
final class FindingCitationLayoutTests: XCTestCase {
    func testCrowdedClaimAddsRowsWithoutExceedingItsWidth() {
        let sources = (1...24).map {
            Source(number: $0, url: "https://example.com/\($0)", title: "Source \($0)", snippet: "")
        }
        let claim = Finding(claim: "A claim", verdict: .insufficient, reasoning: "",
                            sourceNumbers: sources.map(\.number))
        let view = FindingsView(findings: [claim], sources: sources, onSelectSource: { _ in })
            .environment(\.panelTextScale, 1.4)
        let host = NSHostingController(rootView: view)
        let narrow = host.sizeThatFits(in: CGSize(width: 360, height: 2000))
        let wide = host.sizeThatFits(in: CGSize(width: 1200, height: 2000))
        XCTAssertLessThanOrEqual(narrow.width, 360)
        XCTAssertGreaterThan(narrow.height, wide.height)
    }
}
