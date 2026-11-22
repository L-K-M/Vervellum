#if os(Linux)
import Foundation
import XCTest
@testable import VervellumKit

final class LinuxEnvironmentTests: XCTestCase {

    /// A staged backup holds the same threads, so while one survives an erase the
    /// attachments it names must survive too.
    func testEveryCopyOfTheThreadFileCountsAsSurviving() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VervellumErase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let threads = directory.appendingPathComponent("threads.json")
        XCTAssertFalse(LinuxEnvironment.threadFileSurvives(threads))

        for name in ["threads.json", "threads.json.bak", "threads.json.bak.tmp"] {
            let copy = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: copy)
            XCTAssertTrue(LinuxEnvironment.threadFileSurvives(threads), name)
            try FileManager.default.removeItem(at: copy)
        }
    }
}
#endif
