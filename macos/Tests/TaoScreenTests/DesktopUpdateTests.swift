import XCTest
import Sparkle
@testable import TaoScreen

@MainActor
final class DesktopUpdateTests: XCTestCase {
    func testUpdateFeedRequiresHTTPSAndSigningKey() {
        let feed = "https://releases.example.com/appcast-arm64.xml"
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertNil(DesktopUpdates.configuredFeed(in: [:]))
        XCTAssertNil(DesktopUpdates.configuredFeed(in: ["SUFeedURL": feed]))
        XCTAssertNil(DesktopUpdates.configuredFeed(in: ["SUFeedURL": feed, "SUPublicEDKey": "invalid"]))
        XCTAssertNil(DesktopUpdates.configuredFeed(in: ["SUFeedURL": "http://example.com/feed.xml", "SUPublicEDKey": key]))
        XCTAssertEqual(DesktopUpdates.configuredFeed(in: ["SUFeedURL": feed, "SUPublicEDKey": key]), feed)
    }

    func testBackgroundDiscoveryAndFailuresKeepTheUpdateAvailableForRetry() throws {
        // 不启动网络或安装器，直接验证 Sparkle 委托事件驱动的界面状态。
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updates = DesktopUpdates()
        let item = try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "100000015", "sparkle:shortVersionString": "1.0.15",
            "enclosure": ["url": "https://downloads.example.test/macos/1.0.15/TaoScreen-1.0.15-arm64.zip"]
        ]))
        updates.updater(controller.updater, didFindValidUpdate: item)
        XCTAssertEqual(updates.availableVersion, "1.0.15")
        XCTAssertEqual(updates.status, "可更新至 1.0.15")
        updates.updater(controller.updater, didAbortWithError: URLError(.notConnectedToInternet))
        XCTAssertEqual(updates.availableVersion, "1.0.15")
        XCTAssertTrue(updates.status.hasPrefix("检查或更新失败："))
        updates.updater(controller.updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        XCTAssertEqual(updates.availableVersion, "1.0.15")
        XCTAssertEqual(updates.status, "已取消更新，可稍后重试")
        updates.updaterDidNotFindUpdate(controller.updater)
        XCTAssertNil(updates.availableVersion)
    }

    func testNoUpdateReasonsDistinguishCompatibilityAndCurrentVersion() {
        let cases: [(SPUNoUpdateFoundReason, String)] = [
            (.onLatestVersion, "已是最新版本"),
            (.onNewerThanLatestVersion, "当前版本高于服务器发布版本"),
            (.systemIsTooOld, "新版本需要更高版本的 macOS"),
            (.systemIsTooNew, "新版本暂不支持当前 macOS"),
            (.hardwareDoesNotSupportARM64, "新版本仅支持 Apple Silicon")
        ]
        for (reason, message) in cases {
            let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
            XCTAssertEqual(DesktopUpdates.message(for: error), message)
        }
        XCTAssertTrue(DesktopUpdates.message(for: NSError(domain: SUSparkleErrorDomain, code: 999,
                                                          userInfo: [NSLocalizedDescriptionKey: "签名验证失败"])).contains("签名验证失败"))
    }
}
