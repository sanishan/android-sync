import XCTest
@testable import SyncCore

final class NotificationPreviewTests: XCTestCase {
    func testPrivacyKeepsOnlySourceAppAndHidesSenderAndMessage() {
        let preview = NotificationPreview(sourceApp: "WhatsApp", title: "Private sender", body: "Private message", privacyEnabled: true)
        XCTAssertEqual(preview.title, "WhatsApp")
        XCTAssertEqual(preview.subtitle, "")
        XCTAssertEqual(preview.body, "Content hidden because Blur / Stream Mode is enabled.")
        XCTAssertTrue(preview.hidden)
    }
    func testPrivacyHidesDeviceNameInTransferTitle() {
        let preview = NotificationPreview(sourceApp: "Android Sync", title: "Files from Private phone", body: "Private filename", privacyEnabled: true)
        XCTAssertEqual(preview.title, "Android Sync")
        XCTAssertFalse((preview.title + preview.subtitle + preview.body).contains("Private"))
    }
    func testNormalPreviewRetainsMessageAndApp() {
        let preview = NotificationPreview(sourceApp: "Messages", title: "Sender", body: "Hello", privacyEnabled: false)
        XCTAssertEqual(preview.title, "Sender")
        XCTAssertEqual(preview.subtitle, "Messages")
        XCTAssertEqual(preview.body, "Hello")
        XCTAssertFalse(preview.hidden)
    }
}
