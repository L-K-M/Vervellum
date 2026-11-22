import XCTest
import UpdraftCore

/// Vervellum's real release asset set, from `.github/workflows/release.yml`:
/// `Vervellum-<v>-macos-universal.dmg`, `Vervellum-<v>-macos-universal.zip`,
/// `vervellum_<v>_amd64.deb` and `vervellum-linux-amd64.flatpak`. The macOS
/// updater must offer the disk image, then the zip, and never a Linux package.
final class UpdateAssetSelectionTests: XCTestCase {

    func testPrefersTheMacOSDiskImageFromTheRealReleaseAssetSet() throws {
        let release = try decode(assets: [
            "vervellum_1.4.0_amd64.deb",
            "vervellum-linux-amd64.flatpak",
            "Vervellum-1.4.0-macos-universal.zip",
            "Vervellum-1.4.0-macos-universal.dmg",
        ])
        XCTAssertEqual(release.preferredAsset?.name, "Vervellum-1.4.0-macos-universal.dmg")
    }

    func testFallsBackToTheMacOSZipWhenNoDiskImageIsPublished() throws {
        let release = try decode(assets: [
            "vervellum_1.4.0_amd64.deb",
            "vervellum-linux-amd64.flatpak",
            "Vervellum-1.4.0-macos-universal.zip",
        ])
        XCTAssertEqual(release.preferredAsset?.name, "Vervellum-1.4.0-macos-universal.zip")
    }

    func testNeverOffersALinuxPackageWhenNoMacOSAssetExists() throws {
        let release = try decode(assets: [
            "vervellum_1.4.0_amd64.deb",
            "vervellum-linux-amd64.flatpak",
        ])
        XCTAssertNil(release.preferredAsset)
    }

    private func decode(assets: [String]) throws -> GitHubRelease {
        let list = assets.map { name in
            "{ \"name\": \"\(name)\", \"content_type\": \"application/octet-stream\", "
                + "\"size\": 1, \"browser_download_url\": \"https://example.com/\(name)\" }"
        }.joined(separator: ", ")
        let document = Data("""
            { "tag_name": "v1.4.0", "html_url": "https://example.com",
              "prerelease": false, "draft": false, "assets": [\(list)] }
            """.utf8)
        return try JSONDecoder().decode(GitHubRelease.self, from: document)
    }
}
