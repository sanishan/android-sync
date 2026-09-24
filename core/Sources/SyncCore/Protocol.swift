import Foundation
import CryptoKit

public enum ProtocolError: Error { case invalidMessage, oversizedFrame, invalidFile, invalidVersion }
public struct WireMessage {
    public static let currentVersion = 2
    public static let maxFrame = 262_144
    public let version: Int
    public let type: String
    public let id: String
    public let body: [String: Any]
    public let originDeviceId: String?
    public let clock: Int64?
    public let sentAt: Int64?
    public let capability: String?
    public let replyTo: String?
    public init(_ type: String, id: String = UUID().uuidString, _ body: [String: Any] = [:], version: Int = Self.currentVersion, originDeviceId: String? = nil, clock: Int64? = nil, sentAt: Int64? = nil, capability: String? = nil, replyTo: String? = nil) {
        self.version = version; self.type = type; self.id = id; self.body = body
        self.originDeviceId = originDeviceId; self.clock = clock
        self.sentAt = sentAt ?? (version >= 2 ? Int64(Date().timeIntervalSince1970 * 1000) : nil)
        self.capability = capability; self.replyTo = replyTo
    }
    public init(data: Data) throws {
        guard data.count <= Self.maxFrame, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = o["v"] as? Int, (1...2).contains(v) else { throw ProtocolError.invalidVersion }
        guard let t = o["type"] as? String, !t.isEmpty, let id = o["id"] as? String, id.count <= 128,
              let b = o["body"] as? [String: Any] else { throw ProtocolError.invalidMessage }
        let parsedClock = (o["clock"] as? NSNumber)?.int64Value
        guard parsedClock == nil || parsedClock! >= 0 else { throw ProtocolError.invalidMessage }
        self.version = v; self.type = t; self.id = id; self.body = b
        self.originDeviceId = o["originDeviceId"] as? String; self.clock = parsedClock
        self.sentAt = (o["sentAt"] as? NSNumber)?.int64Value; self.capability = o["capability"] as? String; self.replyTo = o["replyTo"] as? String
    }
    public func encoded(protocolVersion: Int? = nil) throws -> Data {
        let selected = protocolVersion ?? version
        guard (1...2).contains(selected) else { throw ProtocolError.invalidVersion }
        var object: [String: Any] = ["v": selected, "type": type, "id": id, "body": body]
        if selected >= 2 {
            if let originDeviceId { object["originDeviceId"] = originDeviceId }
            if let clock { object["clock"] = clock }
            object["sentAt"] = sentAt ?? Int64(Date().timeIntervalSince1970 * 1000)
            if let capability { object["capability"] = capability }
            if let replyTo { object["replyTo"] = replyTo }
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= Self.maxFrame else { throw ProtocolError.oversizedFrame }
        data.append(10); return data
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: body))
    }
    public static func object<T: Encodable>(_ value: T) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any] ?? [:]
    }
}
public enum CapabilityAvailability: String, Codable { case supported, permissionRequired, enabled, temporarilyUnavailable, unsupported }
public struct WireCapability: Codable, Equatable {
    public var id: String
    public var state: CapabilityAvailability
    public var reason: String?
    public init(id: String, state: CapabilityAvailability, reason: String? = nil) { self.id = id; self.state = state; self.reason = reason }
}
public struct WireCapabilitySet: Codable, Equatable {
    public var capabilities: [WireCapability]
    public init(capabilities: [WireCapability]) { self.capabilities = capabilities }
}
public struct LogicalClock {
    private var value: Int64
    public init(_ initial: Int64 = 0) { value = max(0, initial) }
    public mutating func tick() -> Int64 { value += 1; return value }
    public mutating func observe(_ remote: Int64) -> Int64 { value = max(value, max(0, remote)) + 1; return value }
    public var current: Int64 { value }
}
public struct LineFramer {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let end = buffer.firstIndex(of: 10) {
            guard end <= WireMessage.maxFrame else { throw ProtocolError.oversizedFrame }
            if end > 0 { frames.append(Data(buffer[..<end])) }
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= WireMessage.maxFrame else { throw ProtocolError.oversizedFrame }
        return frames
    }
}
public struct SeenEvents {
    private var set = Set<String>()
    private var order: [String] = []
    public init() {}
    public mutating func insert(_ id: String) -> Bool {
        guard set.insert(id).inserted else { return false }
        order.append(id)
        if order.count > 4096 { set.remove(order.removeFirst()) }
        return true
    }
}
public struct PhoneNotification: Codable, Identifiable, Equatable {
    public var id: String
    /// The paired Android device that owns this notification. Nil only for
    /// history written before multi-device notification routing was added.
    public var deviceId: String?
    /// The NotificationListenerService key on the owning Android device.
    public var remoteId: String?
    public var app: String
    public var package: String
    public var appIcon: String?
    public var title: String
    public var text: String
    public var timestamp: Int64
    public var active: Bool
    public var reply: Bool
    public var links: [String]
    public var actions: [NotificationAction]
    public var call: Bool?
    public var callState: String?
    public var callerName: String?
    public var callerNumber: String?
    public var callerImage: String?
    /// Call controls exposed by the current Android call notification. This is
    /// optional so encrypted history written by older builds remains readable.
    public var callActions: [CallNotificationAction]?
    public var localDismissed: Bool?
    public init(id: String, deviceId: String? = nil, remoteId: String? = nil, app: String, package: String, appIcon: String? = nil, title: String, text: String, timestamp: Int64, active: Bool = true, reply: Bool = false, links: [String] = [], actions: [NotificationAction] = [], call: Bool? = nil, callState: String? = nil, callerName: String? = nil, callerNumber: String? = nil, callerImage: String? = nil, callActions: [CallNotificationAction]? = nil, localDismissed: Bool? = false) {
        self.id = id; self.deviceId = deviceId; self.remoteId = remoteId; self.app = app; self.package = package; self.appIcon = appIcon; self.title = title; self.text = text; self.timestamp = timestamp; self.active = active; self.reply = reply; self.links = links; self.actions = actions; self.call = call; self.callState = callState; self.callerName = callerName; self.callerNumber = callerNumber; self.callerImage = callerImage; self.callActions = callActions; self.localDismissed = localDismissed
    }
    public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
}
public struct NotificationAction: Codable, Equatable { public var id: String; public var title: String }
public struct CallNotificationAction: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var requiresText: Bool
    public init(id: String, kind: String, title: String, requiresText: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.requiresText = requiresText
    }
}
public struct SharedFile: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var size: Int64
    public var sha256: String
    public var mime: String
    /// Optional path below the chosen destination. Android shared-storage
    /// folder downloads use this to preserve their directory hierarchy.
    public var relativePath: String? = nil
    public func validate() throws {
        guard UUID(uuidString: id) != nil, size >= 0, size <= 100_000_000_000,
              !name.isEmpty, name.count <= 240, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { throw ProtocolError.invalidFile }
        if let relativePath {
            let parts = relativePath.split(separator: "/",omittingEmptySubsequences: false)
            guard !relativePath.isEmpty, relativePath.count <= 2048, !relativePath.hasPrefix("/"), !relativePath.hasSuffix("/"),
                  !relativePath.contains("\\"), !relativePath.contains("\0"),
                  !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 240 }),
                  parts.last.map(String.init) == name else { throw ProtocolError.invalidFile }
        }
    }
}
public struct FileOffer: Codable, Identifiable, Equatable {
    public var id: String
    public var files: [SharedFile]
    public var targetPath: String?
    public init(id: String = UUID().uuidString, files: [SharedFile], targetPath: String? = nil) { self.id = id; self.files = files; self.targetPath = targetPath }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, !files.isEmpty, files.count <= 100, Set(files.map(\.id)).count == files.count else { throw ProtocolError.invalidFile }
        let relativePaths = files.compactMap(\.relativePath)
        guard Set(relativePaths).count == relativePaths.count else { throw ProtocolError.invalidFile }
        if let targetPath, !targetPath.isEmpty, !SyncRules.validSharedStoragePath(targetPath) { throw ProtocolError.invalidFile }
        try files.forEach { try $0.validate() }
    }
}
public struct StorageEntry: Codable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var directory: Bool
    public var size: Int64
    public var modified: Int64
    public var mime: String
}
public struct MediaEntry: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var size: Int64
    public var modified: Int64
    public var mime: String
    public var width: Int
    public var height: Int
    public var duration: Int64
    public var isVideo: Bool { mime.hasPrefix("video/") }
}
public struct SmsThreadRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var address: String
    public var contactName: String?
    public var snippet: String
    public var timestamp: Int64
    public var unreadCount: Int
    public var deviceId: String?
}
public struct SmsMessageRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var threadId: String
    public var address: String
    public var body: String
    public var timestamp: Int64
    public var outgoing: Bool
    public var read: Bool
    public var deviceId: String?
}
public struct ContactRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var phones: [String]
    public var deviceId: String?
}
public struct CallHistoryRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var number: String
    public var name: String?
    public var timestamp: Int64
    public var duration: Int64
    public var type: Int
    public var deviceId: String?
    public init(id: String, number: String, name: String?, timestamp: Int64, duration: Int64, type: Int, deviceId: String? = nil) {
        self.id = id; self.number = number; self.name = name; self.timestamp = timestamp; self.duration = duration; self.type = type; self.deviceId = deviceId
    }
}
public struct MediaStateRecord: Codable, Equatable {
    public var packageName: String
    public var app: String
    public var title: String
    public var artist: String
    public var playing: Bool
    public var actions: [String]
}
public struct StreamOfferRecord: Codable, Equatable {
    public var sessionId: String
    public var kind: String
    public var codec: String
    public var control: Bool
}
public struct RealtimeFrameAssembly {
    public let count: Int
    public let presentationTime: Int64
    public let keyFrame: Bool
    private var parts: [Int: Data] = [:]
    private var byteCount = 0
    public init(count: Int, presentationTime: Int64, keyFrame: Bool) { self.count = count; self.presentationTime = presentationTime; self.keyFrame = keyFrame }
    public mutating func append(index: Int, data: Data) -> Data? {
        guard count > 0, count <= 64, index >= 0, index < count, parts[index] == nil, byteCount + data.count <= 4 * 1024 * 1024 else { return nil }
        parts[index] = data; byteCount += data.count
        guard parts.count == count else { return nil }
        return (0..<count).reduce(into: Data()) { output, index in output.append(parts[index]!) }
    }
}
public enum SyncRules {
    public static func validSharedStoragePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 1024, !path.contains("\\"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else { return false }
        let lower = path.lowercased()
        return lower != "android/data" && !lower.hasPrefix("android/data/") && lower != "android/obb" && !lower.hasPrefix("android/obb/")
    }
    public static func notificationIdentifier(deviceId: String, remoteId: String) -> String {
        "\(deviceId)::\(remoteId)"
    }
    public static func notificationActionFailure(_ item: PhoneNotification?, kind: String, text: String? = nil, actionId: String? = nil, expectedTimestamp: Int64? = nil) -> String? {
        guard let item, item.active else { return "This notification is no longer active on your phone. Reply to a current notification." }
        if let expectedTimestamp, expectedTimestamp != item.timestamp { return "This notification changed. Review the latest notification before replying." }
        if kind == "reply" {
            guard item.reply else { return "This Android notification does not support text replies. Reply on your phone." }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 16000 else { return "Enter a reply of at most 16,000 characters." }
        }
        if kind == "call" {
            guard let actionId, let action = item.callActions?.first(where: { $0.id == actionId }) else {
                return "This call control is no longer available. Refresh notifications and use the current call notification."
            }
            if action.requiresText {
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 16000 else {
                    return "Enter a message of at most 16,000 characters."
                }
            }
        }
        return nil
    }
    public static func prune(_ items: [PhoneNotification], now: Date = Date()) -> [PhoneNotification] {
        items.filter { $0.date >= now.addingTimeInterval(-7 * 86400) }
    }
    public static func upsert(_ notification: PhoneNotification, into items: inout [PhoneNotification]) {
        if let index = items.firstIndex(where: { $0.id == notification.id }) {
            var updated = notification; updated.localDismissed = items[index].localDismissed; items[index] = updated
        } else { items.insert(notification, at: 0) }
    }
    public static func validWebURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    public static func signaturePayload(macId: String, nonce: String, stream: String, phoneId: String) -> Data {
        Data("android-sync/1|\(macId)|\(nonce)|\(stream)|\(phoneId)".utf8)
    }
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    public static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let part = try handle.read(upToCount: 65536), !part.isEmpty { hash.update(data: part) }
        return hex(Data(hash.finalize()))
    }
}
