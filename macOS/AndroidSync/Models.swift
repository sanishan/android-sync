import Foundation
import CryptoKit
import AppKit

struct TrustedPhone: Codable, Identifiable {
    var id: String
    var name: String
    var publicKey: String
}
struct TransferRecord: Codable, Identifiable {
    var id: String { offer.id }
    var offer: FileOffer
    var phoneId: String
    var incoming: Bool
    var status: String
    var accepted: Bool = false
    var completed: [String] = []
    var sourcePaths: [String: String] = [:]
    var savedPaths: [String: String] = [:]
    var receiveFolderPath: String?
    var completionNotified: Bool?
    var failureNotified: Bool?
    var bytes: Int64 = 0
    var speedBytesPerSecond: Int64?
    var startedAt: Date?
    var date = Date()
    var total: Int64 { offer.files.reduce(0) { $0 + $1.size } }
}
struct PhoneSyncStatus {
    var notificationAccess: Bool
    var listenerConnected: Bool
    var clipboardMode: String
    var messagesAccess: Bool? = nil
    var messagesPermissions: Bool? = nil
    var protocolVersion: Int = 1
    var lanes: [String] = ["control"]
    var capabilities: [String: String] = [:]
}
struct ClipboardImageSource {
    var url: URL
    var size: Int64
    var sha256: String
    var mime: String
    var origin: String
    var sourceApp: String?
    var width: Int
    var height: Int
    var originDeviceId: String = ""
    var logicalClock: Int64 = 0
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}
struct ClipboardRecord: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var deviceId: String
    var deviceName: String
    var origin: String
    var sourceApp: String
    var kind: String
    var text: String
    var imageFileName: String?
    var width: Int?
    var height: Int?
    var logicalClock: Int64? = 0
    var contentHash: String? = nil
    var byteSize: Int64? = nil
    var pinned: Bool? = false
    var createdAt: Date = Date()
    var isImage: Bool { kind == "image" }
    var isLink: Bool { kind == "link" }
}
struct ClipboardDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var connected: Bool
    var local: Bool
}
struct StorageListing: Codable {
    var requestId: String
    var path: String
    var parent: String?
    var entries: [StorageEntry]
    var offset: Int?
    var nextOffset: Int?
    var hasMore: Bool?
    var state: String
    var reason: String?
}
struct MediaListing: Codable {
    var requestId: String
    var cursor: Int
    var nextCursor: Int?
    var hasMore: Bool
    var entries: [MediaEntry]
    var state: String
    var reason: String?
}
struct HistoryState: Codable {
    var notifications: [PhoneNotification] = []
    var notificationAppIcons: [String: Data] = [:]
    var transfers: [TransferRecord] = []
    var excluded: Set<String> = []
    var pausedClipboard = false
    var clearedAt: Int64 = 0
    var clipboardHistory: [ClipboardRecord] = []
    var clipboardTombstones: [String] = []
    var pausedClipboardDevices: Set<String> = []
    var askEveryTimeFiles: Set<String> = []
    var smsThreads: [SmsThreadRecord] = []
    var smsMessages: [SmsMessageRecord] = []
    var contacts: [ContactRecord] = []
    var callHistory: [CallHistoryRecord] = []

    enum CodingKeys: String, CodingKey { case notifications, notificationAppIcons, transfers, excluded, pausedClipboard, clearedAt, clipboardHistory, clipboardTombstones, pausedClipboardDevices, askEveryTimeFiles, smsThreads, smsMessages, contacts, callHistory }
    init(notifications: [PhoneNotification] = [], notificationAppIcons: [String: Data] = [:], transfers: [TransferRecord] = [], excluded: Set<String> = [], pausedClipboard: Bool = false, clearedAt: Int64 = 0, clipboardHistory: [ClipboardRecord] = [], clipboardTombstones: [String] = [], pausedClipboardDevices: Set<String> = [], askEveryTimeFiles: Set<String> = [], smsThreads: [SmsThreadRecord] = [], smsMessages: [SmsMessageRecord] = [], contacts: [ContactRecord] = [], callHistory: [CallHistoryRecord] = []) {
        self.notifications = notifications; self.notificationAppIcons = notificationAppIcons; self.transfers = transfers; self.excluded = excluded
        self.pausedClipboard = pausedClipboard; self.clearedAt = clearedAt; self.clipboardHistory = clipboardHistory; self.clipboardTombstones = clipboardTombstones; self.pausedClipboardDevices = pausedClipboardDevices; self.askEveryTimeFiles = askEveryTimeFiles
        self.smsThreads = smsThreads; self.smsMessages = smsMessages; self.contacts = contacts; self.callHistory = callHistory
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try values.decodeIfPresent([PhoneNotification].self, forKey: .notifications) ?? []
        notificationAppIcons = try values.decodeIfPresent([String: Data].self, forKey: .notificationAppIcons) ?? [:]
        transfers = try values.decodeIfPresent([TransferRecord].self, forKey: .transfers) ?? []
        excluded = try values.decodeIfPresent(Set<String>.self, forKey: .excluded) ?? []
        pausedClipboard = try values.decodeIfPresent(Bool.self, forKey: .pausedClipboard) ?? false
        clearedAt = try values.decodeIfPresent(Int64.self, forKey: .clearedAt) ?? 0
        clipboardHistory = try values.decodeIfPresent([ClipboardRecord].self, forKey: .clipboardHistory) ?? []
        clipboardTombstones = try values.decodeIfPresent([String].self, forKey: .clipboardTombstones) ?? []
        pausedClipboardDevices = try values.decodeIfPresent(Set<String>.self, forKey: .pausedClipboardDevices) ?? []
        askEveryTimeFiles = try values.decodeIfPresent(Set<String>.self, forKey: .askEveryTimeFiles) ?? []
        smsThreads = try values.decodeIfPresent([SmsThreadRecord].self, forKey: .smsThreads) ?? []
        smsMessages = try values.decodeIfPresent([SmsMessageRecord].self, forKey: .smsMessages) ?? []
        contacts = try values.decodeIfPresent([ContactRecord].self, forKey: .contacts) ?? []
        callHistory = try values.decodeIfPresent([CallHistoryRecord].self, forKey: .callHistory) ?? []
    }
}
final class EncryptedHistory {
    let directory: URL
    let key: SymmetricKey
    init(directory override: URL? = nil) throws {
        directory = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Android Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        key = try Vault.encryptionKey()
    }
    func load() throws -> HistoryState {
        let url = directory.appendingPathComponent("history.enc")
        guard FileManager.default.fileExists(atPath: url.path) else { return HistoryState() }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        return try JSONDecoder().decode(HistoryState.self, from: AES.GCM.open(sealed, using: key))
    }
    func save(_ state: HistoryState) throws {
        let data = try AES.GCM.seal(JSONEncoder().encode(state), using: key).combined!
        let url = directory.appendingPathComponent("history.enc")
        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private var clipboardDirectory: URL { directory.appendingPathComponent("Clipboard", isDirectory: true) }
    func saveClipboardImage(_ data: Data, id: String) throws -> String {
        guard UUID(uuidString: id) != nil, !data.isEmpty, data.count <= 25 * 1024 * 1024 else { throw ProtocolError.invalidFile }
        try FileManager.default.createDirectory(at: clipboardDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "\(id).clip"
        let sealed = try AES.GCM.seal(data, using: key).combined!
        let url = clipboardDirectory.appendingPathComponent(name)
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return name
    }
    func loadClipboardImage(_ name: String) throws -> Data {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".clip") else { throw ProtocolError.invalidFile }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: clipboardDirectory.appendingPathComponent(name)))
        return try AES.GCM.open(sealed, using: key)
    }
    func removeClipboardImage(_ name: String) {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".clip") else { return }
        try? FileManager.default.removeItem(at: clipboardDirectory.appendingPathComponent(name))
    }
}
