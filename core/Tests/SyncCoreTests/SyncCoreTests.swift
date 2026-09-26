import XCTest
import CryptoKit
@testable import SyncCore

final class SyncCoreTests: XCTestCase {
    func testRedactedDiagnosticsSchemaContainsOnlyAggregateState() throws {
        let report = RedactedDiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            app: .init(name: "Android Sync", version: "1.0.0", build: "8"),
            platform: .init(name: "macOS", version: "26", runtimeArchitecture: "arm64", buildArchitectures: ["arm64", "x86_64"]),
            devices: .init(paired: 2, connected: 1),
            health: .init(nativeAlerts: "enabled", clipboardPaused: false),
            historyCounts: .init(notifications: 3, clipboard: 4, transfers: 5, smsThreads: 6, smsMessages: 7, contacts: 8),
            transferStates: ["completed": 4, "active": 1],
            phoneCapabilityStates: ["enabled": 3, "permission_required": 2]
        )
        let data = try JSONEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"paired\":2"))
        for privateValue in ["clipboard message", "192.168.1.8", "/Users/person/Downloads", "phone-device-id"] {
            XCTAssertFalse(text.contains(privateValue))
        }
    }
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!) }
    func testAndroidNotificationFixture() throws {
        let wire = try WireMessage(data: fixture("notification")); let item = try wire.decode(PhoneNotification.self)
        XCTAssertEqual(item.app,"Messages"); XCTAssertTrue(item.reply); XCTAssertTrue(item.text.contains("👋")); XCTAssertEqual(item.actions.first?.id,"1")
        XCTAssertEqual(Data(base64Encoded: item.appIcon ?? "")?.count, 68)
        let encoded = try wire.encoded(); XCTAssertEqual(encoded.last,10)
        XCTAssertEqual(try WireMessage(data: encoded.dropLast()).decode(PhoneNotification.self),item)
    }
    func testCallNotificationFixtureExposesOnlyCurrentControls() throws {
        let item = try WireMessage(data: fixture("call-notification")).decode(PhoneNotification.self)
        XCTAssertEqual(item.call,true)
        XCTAssertEqual(item.callState,"incoming")
        XCTAssertEqual(item.callerName,"Taylor Reed")
        XCTAssertEqual(item.callerNumber,"+1 202-555-0147")
        XCTAssertEqual(item.callActions?.map(\.kind),["answer","decline","mute","declineMessage"])
        let message = item.callActions!.last!
        XCTAssertTrue(message.requiresText)
        XCTAssertNil(SyncRules.notificationActionFailure(item,kind:"call",text:"Can't talk now",actionId:message.id,expectedTimestamp:item.timestamp))
        XCTAssertNotNil(SyncRules.notificationActionFailure(item,kind:"call",actionId:message.id,expectedTimestamp:item.timestamp))
        XCTAssertNotNil(SyncRules.notificationActionFailure(item,kind:"call",actionId:"removed",expectedTimestamp:item.timestamp))
    }
    func testAndroidClipboardImageFixture() throws {
        let wire = try WireMessage(data: fixture("clipboard-image-put"))
        XCTAssertEqual(wire.type, "clipboard.put")
        XCTAssertEqual((wire.body["size"] as? NSNumber)?.int64Value, 24_576)
        XCTAssertEqual(wire.body["mime"] as? String, "image/png")
        XCTAssertEqual((wire.body["sha256"] as? String)?.count, 64)
        XCTAssertEqual(wire.body["sourceApp"] as? String, "Gallery")
    }
    func testClipboardEventFixtureKeepsStableMeshIdentity() throws {
        let wire = try WireMessage(data: fixture("clipboard-event-v2"))
        XCTAssertEqual(wire.id,wire.body["clipId"] as? String)
        XCTAssertEqual(wire.originDeviceId,wire.body["originDeviceId"] as? String)
        XCTAssertEqual(wire.clock,84)
        XCTAssertEqual((wire.body["contentHash"] as? String)?.count,64)
    }
    func testSharedStorageFixtureIsReadOnlyMetadata() throws {
        let wire = try WireMessage(data: fixture("storage-list-v2"))
        XCTAssertEqual(wire.capability,"files")
        XCTAssertEqual(wire.replyTo,"storage-request-1")
        let entries = try JSONDecoder().decode([StorageEntry].self,from: JSONSerialization.data(withJSONObject: wire.body["entries"] as Any))
        XCTAssertTrue(entries[0].directory)
        XCTAssertEqual(entries[1].path,"Download/notes.txt")
        XCTAssertEqual(entries[1].size,128)
        XCTAssertEqual(wire.body["offset"] as? Int,0)
        XCTAssertEqual(wire.body["nextOffset"] as? Int,2)
        XCTAssertEqual(wire.body["hasMore"] as? Bool,true)
        XCTAssertTrue(SyncRules.validSharedStoragePath("Download/Android Sync"))
        XCTAssertFalse(SyncRules.validSharedStoragePath("Android/data/example"))
        XCTAssertFalse(SyncRules.validSharedStoragePath("../Download"))
        let file = SharedFile(id: "c4c08708-64c0-45d5-af49-9a04e20a334b",name: "root.txt",size: 0,sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",mime: "text/plain")
        XCTAssertNoThrow(try FileOffer(files: [file],targetPath: "").validate())
    }
    func testPagedGalleryFixtureSeparatesMediaMetadataFromThumbnails() throws {
        let wire = try WireMessage(data: fixture("gallery-list-v2"))
        XCTAssertEqual(wire.type,"gallery.list.result")
        XCTAssertEqual(wire.capability,"files")
        let entries = try JSONDecoder().decode([MediaEntry].self,from: JSONSerialization.data(withJSONObject: wire.body["entries"] as Any))
        XCTAssertEqual(entries.count,2)
        XCTAssertFalse(entries[0].isVideo)
        XCTAssertTrue(entries[1].isVideo)
        XCTAssertEqual(entries[1].duration,12_400)
        XCTAssertEqual(wire.body["nextCursor"] as? Int,20)
        XCTAssertEqual(wire.body["hasMore"] as? Bool,true)
        XCTAssertNil(wire.body["data"],"Thumbnail bytes use separate bounded responses")
    }
    func testGeneratedSmsFixtureNeverInvokesARecipient() throws {
        let wire = try WireMessage(data: fixture("sms-message-v2"))
        let message = try wire.decode(SmsMessageRecord.self)
        XCTAssertEqual(wire.capability,"sms")
        XCTAssertEqual(message.threadId,"92")
        XCTAssertEqual(message.body,"Generated fixture message")
        XCTAssertFalse(message.outgoing)
    }
    func testScreenOfferFixtureRequiresExplicitSessionAndCodec() throws {
        let wire = try WireMessage(data: fixture("stream-offer-v2")); let offer = try wire.decode(StreamOfferRecord.self)
        XCTAssertEqual(wire.type,"stream.offer"); XCTAssertEqual(wire.capability,"realtime")
        XCTAssertEqual(offer.kind,"screen"); XCTAssertEqual(offer.codec,"h264"); XCTAssertTrue(offer.control)
    }
    func testRealtimeFrameAssemblyOrdersChunksAndRejectsDuplicates() {
        var frame = RealtimeFrameAssembly(count: 3,presentationTime: 42,keyFrame: true)
        XCTAssertNil(frame.append(index: 2,data: Data("C".utf8)))
        XCTAssertNil(frame.append(index: 0,data: Data("A".utf8)))
        XCTAssertNil(frame.append(index: 0,data: Data("duplicate".utf8)))
        XCTAssertEqual(frame.append(index: 1,data: Data("B".utf8)),Data("ABC".utf8))
    }
    func testFragmentedAndCoalescedFrames() throws {
        let a = try WireMessage("ping").encoded(); let b = try WireMessage("pong").encoded()
        var framer = LineFramer(); XCTAssertTrue(try framer.append(a.prefix(5)).isEmpty)
        let lines = try framer.append(a.dropFirst(5)+b); XCTAssertEqual(lines.count,2)
        XCTAssertEqual(try WireMessage(data: lines[0]).type,"ping")
    }
    func testOversizedFramesAndUnknownVersion() throws {
        var framer = LineFramer(); XCTAssertThrowsError(try framer.append(Data(repeating: 65,count: WireMessage.maxFrame+1)))
        XCTAssertThrowsError(try WireMessage(data: Data("{\"v\":3,\"type\":\"ping\",\"id\":\"x\",\"body\":{}}".utf8)))
    }
    func testV2EnvelopeAndV1Downgrade() throws {
        let wire = try WireMessage(data: fixture("envelope-v2"))
        XCTAssertEqual(wire.version, 2); XCTAssertEqual(wire.clock, 42); XCTAssertEqual(wire.capability, "clipboard")
        let downgraded = try WireMessage(data: try wire.encoded(protocolVersion: 1).dropLast())
        XCTAssertEqual(downgraded.version, 1); XCTAssertNil(downgraded.originDeviceId); XCTAssertNil(downgraded.clock)
    }
    func testLogicalClockOrdersRemoteEvents() {
        var clock = LogicalClock(); XCTAssertEqual(clock.tick(), 1); XCTAssertEqual(clock.observe(7), 8); XCTAssertEqual(clock.tick(), 9)
    }
    func testDeduplicationAndBoundedCache() {
        var seen = SeenEvents(); XCTAssertTrue(seen.insert("reply")); XCTAssertFalse(seen.insert("reply"))
        for i in 0..<4096 { XCTAssertTrue(seen.insert("\(i)")) }; XCTAssertTrue(seen.insert("reply"))
    }
    func testZeroLengthFileAndUnsafeNames() throws {
        let offer = try WireMessage(data: fixture("file-offer")).decode(FileOffer.self); try offer.validate()
        XCTAssertEqual(offer.files[0].relativePath,"Notes/Empty.txt")
        var file = offer.files[0]; file.name = "../escape"; XCTAssertThrowsError(try file.validate())
        file = offer.files[0]; file.relativePath = "../Empty.txt"; XCTAssertThrowsError(try file.validate())
        file = offer.files[0]; file.relativePath = "Other/name.txt"; XCTAssertThrowsError(try file.validate())
        file = offer.files[0]; file.size = -1; XCTAssertThrowsError(try file.validate())
        file = offer.files[0]; file.sha256 = "no"; XCTAssertThrowsError(try file.validate())
        var duplicate = offer; duplicate.files.append(offer.files[0]); XCTAssertThrowsError(try duplicate.validate())
        var duplicatePath = offer; file = offer.files[0]; file.id = UUID().uuidString; duplicatePath.files.append(file); XCTAssertThrowsError(try duplicatePath.validate())
    }
    func testBinaryFileOfferNeedsAValidTokenAndLegacyStillDecodes() throws {
        let legacy = try WireMessage(data: fixture("file-offer")).decode(FileOffer.self)
        XCTAssertNil(legacy.transport)
        XCTAssertNoThrow(try legacy.validate())
        for mode in ["tls-binary", "plain-binary"] {
            let offer = FileOffer(files: legacy.files,transport: mode,transferToken: String(repeating: "a",count: 64))
            try offer.validate()
            let decoded = try JSONDecoder().decode(FileOffer.self,from: JSONEncoder().encode(offer))
            XCTAssertEqual(decoded,offer)
        }
        XCTAssertThrowsError(try FileOffer(files: legacy.files,transport: "plain-binary").validate())
        XCTAssertThrowsError(try FileOffer(files: legacy.files,transport: "unknown",transferToken: String(repeating: "a",count: 64)).validate())
    }
    func testFileTransportSettingConvergesWithoutEcho() {
        XCTAssertTrue(FileTransportSettingOrder.shouldAdopt(revision: 11,origin: "phone",currentRevision: 10,currentOrigin: "mac"))
        XCTAssertFalse(FileTransportSettingOrder.shouldAdopt(revision: 9,origin: "phone",currentRevision: 10,currentOrigin: "mac"))
        XCTAssertFalse(FileTransportSettingOrder.shouldAdopt(revision: 10,origin: "mac",currentRevision: 10,currentOrigin: "mac"))
        XCTAssertTrue(FileTransportSettingOrder.shouldAdopt(revision: 10,origin: "phone",currentRevision: 10,currentOrigin: "mac"))
    }
    func testDismissalSurvivesUpdatesAndExpiry() {
        let now = Date()
        var items = [PhoneNotification(id:"one",app:"A",package:"a",title:"Old",text:"Old",timestamp:Int64(now.timeIntervalSince1970*1000),localDismissed:true)]
        SyncRules.upsert(PhoneNotification(id:"one",app:"A",package:"a",title:"New",text:"New",timestamp:Int64(now.timeIntervalSince1970*1000)),into:&items)
        XCTAssertEqual(items[0].title,"New"); XCTAssertEqual(items[0].localDismissed,true)
        items.append(PhoneNotification(id:"old",app:"A",package:"a",title:"",text:"",timestamp:Int64(now.addingTimeInterval(-8*86400).timeIntervalSince1970*1000)))
        XCTAssertEqual(SyncRules.prune(items,now:now).count,1)
    }
    func testNotificationIdentityIsScopedToItsAndroidDevice() throws {
        let remote = "0|com.example.app|42|null|1000"
        let a = SyncRules.notificationIdentifier(deviceId: "11111111-1111-1111-1111-111111111111", remoteId: remote)
        let b = SyncRules.notificationIdentifier(deviceId: "22222222-2222-2222-2222-222222222222", remoteId: remote)
        XCTAssertNotEqual(a, b)
        let item = PhoneNotification(id: a, deviceId: "11111111-1111-1111-1111-111111111111", remoteId: remote, app: "Messages", package: "com.example.app", title: "Hello", text: "World", timestamp: 42, reply: true)
        XCTAssertEqual(try JSONDecoder().decode(PhoneNotification.self, from: JSONEncoder().encode(item)), item)
    }
    func testWebLinksRejectPrivilegedSchemes() {
        XCTAssertNotNil(SyncRules.validWebURL("https://example.com/continue")); XCTAssertNil(SyncRules.validWebURL("file:///etc/passwd")); XCTAssertNil(SyncRules.validWebURL("javascript:alert(1)"))
    }
    func testAuthenticationBindsEveryIdentityAndStream() throws {
        let key = P256.Signing.PrivateKey()
        let payload = SyncRules.signaturePayload(macId:"mac",nonce:"nonce",stream:"control",phoneId:"phone")
        let sig = try key.signature(for:payload)
        XCTAssertTrue(key.publicKey.isValidSignature(sig,for:payload))
        for change in [SyncRules.signaturePayload(macId:"other",nonce:"nonce",stream:"control",phoneId:"phone"),SyncRules.signaturePayload(macId:"mac",nonce:"new",stream:"control",phoneId:"phone"),SyncRules.signaturePayload(macId:"mac",nonce:"nonce",stream:"file",phoneId:"phone"),SyncRules.signaturePayload(macId:"mac",nonce:"nonce",stream:"control",phoneId:"other")] { XCTAssertFalse(key.publicKey.isValidSignature(sig,for:change)) }
    }
    func testReplyRequiresCurrentActiveNotification() {
        var item = PhoneNotification(id:"fixture",app:"Test",package:"test",title:"Test",text:"",timestamp:42,reply:true)
        XCTAssertNil(SyncRules.notificationActionFailure(item,kind:"reply",text:"Hello 👋",expectedTimestamp:42))
        item.active = false
        XCTAssertTrue(SyncRules.notificationActionFailure(item,kind:"reply",text:"Hello")!.contains("no longer active"))
        item.active = true
        XCTAssertTrue(SyncRules.notificationActionFailure(item,kind:"reply",text:"Hello",expectedTimestamp:41)!.contains("changed"))
        item.reply = false
        XCTAssertNotNil(SyncRules.notificationActionFailure(item,kind:"reply",text:"Hello"))
        item.reply = true
        XCTAssertNotNil(SyncRules.notificationActionFailure(item,kind:"reply",text:"  \n"))
        XCTAssertNotNil(SyncRules.notificationActionFailure(item,kind:"reply",text:String(repeating:"a",count:16001)))
    }
}
