import Foundation
import XCTest
#if canImport(VervellumKit)
@testable import VervellumKit
#else
@testable import Vervellum
#endif

final class AssessmentCitationTests: XCTestCase {

    // Decode real JSON: Foundation bridges both booleans and numbers through NSNumber.
    func testRejectsBooleanAndFractionalJSONCitations() throws {
        for value in ["true", "false", "0.6", "1.4", "1.6", "2.5"] {
            let assessment = try parseJSON(sources: "[\(value)]")
            XCTAssertTrue(assessment.findings.isEmpty, value)
            XCTAssertTrue(assessment.notices.contains(.invalidCitation), value)
            XCTAssertTrue(assessment.notices.contains(.uncitedVerdictDropped), value)
        }
    }

    func testKeepsExactJSONIntegersAndIntegerStrings() throws {
        let assessment = try parseJSON(sources: #"[1, 2.0, 3e0, " 2 "]"#)
        XCTAssertEqual(assessment.findings.first?.sourceNumbers, [1, 2, 3])
        XCTAssertTrue(assessment.notices.isEmpty)
    }

    func testKeepsValidReferencesButReportsEveryMalformedKind() throws {
        for value in ["true", "1.6", "null", #""not a number""#, #""1.5""#, "{}", "[]",
                      "0", "-1", "99", "1e308", #""9223372036854775808""#] {
            let assessment = try parseJSON(sources: "[2, \(value)]")
            XCTAssertEqual(assessment.findings.first?.sourceNumbers, [2], value)
            XCTAssertTrue(assessment.notices.contains(.invalidCitation), value)
            XCTAssertFalse(assessment.notices.contains(.uncitedVerdictDropped), value)
        }
    }

    func testNonFiniteAndBoundaryValuesNeverBecomeCitations() throws {
        for value in [Double.nan, .infinity, -.infinity, Double(Int.max), Double(Int.min)] {
            let finding: [String: Any] = [
                "claim": "Claim", "verdict": "supported", "sources": [value],
            ]
            let assessment = try AssessmentParser.parse(["findings": [finding]], sourceCount: 3)
            XCTAssertTrue(assessment.findings.isEmpty)
            XCTAssertTrue(assessment.notices.contains(.invalidCitation))
        }
    }

    func testInvalidCitationsDoNotEraseNonEvidentialVerdicts() throws {
        for verdict in ["insufficient", "opinion"] {
            let assessment = try parseJSON(sources: "[true, 1.5]", verdict: verdict)
            XCTAssertEqual(assessment.findings.count, 1)
            XCTAssertEqual(assessment.findings.first?.sourceNumbers, [])
            XCTAssertTrue(assessment.notices.contains(.invalidCitation))
            XCTAssertFalse(assessment.notices.contains(.uncitedVerdictDropped))
        }
    }

    func testEveryEvidentialVerdictStillRequiresARealCitation() throws {
        for verdict in ["supported", "contradicted", "mixed"] {
            let assessment = try parseJSON(sources: "[1.6]", verdict: verdict)
            XCTAssertTrue(assessment.findings.isEmpty)
            XCTAssertTrue(assessment.notices.contains(.uncitedVerdictDropped))
        }
    }

    private func parseJSON(sources: String, verdict: String = "supported") throws -> AssessmentParser.Assessment {
        let json = """
            {"findings":[{"claim":"Claim","verdict":"\(verdict)","sources":\(sources)}]}
            """
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try AssessmentParser.parse(object, sourceCount: 3)
    }
}
