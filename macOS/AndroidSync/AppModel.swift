import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import CryptoKit
import UniformTypeIdentifiers
import Combine

@MainActor final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var notifications: [PhoneNotification] = []
    @Published var notificationAppIcons: [String: Data] = [:]
    @Published var transfers: [TransferRecord] = []
    @Published var phones: [TrustedPhone] = []
    @Published var connected: Set<String> = []
    @Published var excluded: Set<String> = []
    @Published var clipboardPaused = false
    @Published var clipboardText = ""
    @Published var clipboardOrigin = "Nothing shared yet"
    @Published var clipboardSourceApp = "Source unavailable"
    @Published var clipboardImage: NSImage?
    @Published var clipboardHistory: [ClipboardRecord] = []
    @Published var pausedClipboardDevices: Set<String> = []
    @Published var clipboardQuotaBytes: Int64
    @Published var status = "Starting local connection…"
    @Published var error: String?
    @Published var port: UInt16 = 0
    @Published var invitation = ""
    @Published var invitationExpires = Date.distantPast
    @Published var commandStates: [String: String] = [:]
    @Published var commandDetails: [String: String] = [:]
    @Published var receivedLinks: [String] = []
    @Published var preparingFiles = false
    @Published var phoneStatuses: [String: PhoneSyncStatus] = [:]
    @Published var alertsStatus = "Checking…"
    @Published var alertsAuthorized = false
    @Published var requestingAlerts = false
    @Published var requestedSection: String?
    @Published var receiveFolder: URL
    @Published var fileAlerts: Bool
    @Published var fileSounds: Bool
    @Published var askEveryTimeFiles: Set<String> = []
    @Published var remoteStorageEntries: [StorageEntry] = []
    @Published var remoteStoragePath = ""
    @Published var remoteStorageParent: String?
    @Published var remoteStoragePhoneId: String?
    @Published var remoteStorageLoading = false
    @Published var remoteStorageMessage: String?
    @Published var remoteStorageHasMore = false
    @Published var remoteStorageNextOffset = 0
    @Published var remoteStorageTransferId: String?
    @Published var galleryEntries: [MediaEntry] = []
    @Published var galleryPhoneId: String?
    @Published var galleryLoading = false
    @Published var galleryHasMore = false
    @Published var galleryNextCursor = 0
    @Published var galleryMessage: String?
    @Published var galleryTransferId: String?
    @Published var galleryThumbnails: [String: Data] = [:]
    @Published var smsThreads: [SmsThreadRecord] = []
    @Published var smsMessages: [SmsMessageRecord] = []
    @Published var contacts: [ContactRecord] = []
    @Published var callHistory: [CallHistoryRecord] = []
    @Published var callHistoryLoading = false
    @Published var callHistoryHasMore: [String: Bool] = [:]
    @Published var callHistoryStatus: [String: String] = [:]
    @Published var dialStatus: [String: String] = [:]
    @Published var smsStatus: [String: String] = [:]
    @Published var smsCommandStates: [String: String] = [:]
    @Published var smsCommandDetails: [String: String] = [:]
    @Published var mirrorPhoneId: String?
    @Published var mirrorSessionId: String?
    @Published var mirrorStatus = "Choose a connected Android device."
    @Published var mirrorFrame: NSImage?
    @Published var mirrorWidth = 0
    @Published var mirrorHeight = 0
    @Published var mirrorControlEnabled = false
    @Published var mirrorBitrate = 4_000_000
    @Published var mirrorAppliedBitrate: Int?
    @Published var remoteControlStatus: String?
    @Published var mediaStates: [String: MediaStateRecord] = [:]
    @Published var adbStatus = "Advanced mirroring is optional."
    @Published var adbAvailable = false
    @Published var lastNotificationReceived: Date?
    private var identity: MacIdentity?
    private var history: EncryptedHistory?
    private var server: LocalServer?
    private var controls: [String: PeerConnection] = [:]
    private var seen = SeenEvents()
    private var secret = ""
    private var clipboardCount = 0
    private let pasteboard: NSPasteboard
    private let persistsPreferences: Bool
    private let alertsEnabled: Bool
    private let allowedNotificationPackages: Set<String>?
    private var clipboardRevisions: [String: (session: String, revision: Int64)] = [:]
    private var lastLiveClipboardOrder: (clock: Int64, origin: String) = (0, "")
    private var clipboardTombstones = Set<String>()
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?
    private var alertAuthorizationCallbacks: [() -> Void] = []
    private var clearedAt: Int64 = 0
    private var snapshotKeys: [String: Set<String>] = [:]
    private var commandNotification: [String: String] = [:]
    private var commandPhone: [String: String] = [:]
    private var latestNotificationCommand: [String: String] = [:]
    private var clipboardImages: [String: ClipboardImageSource] = [:]
    private var pendingSmsThreads: [String: [SmsThreadRecord]] = [:]
    private var pendingSmsMessages: [String: [SmsMessageRecord]] = [:]
    private var pendingContacts: [String: [ContactRecord]] = [:]
    private var pendingCallPages: [String: (phoneId: String, offset: Int)] = [:]
    private var pendingDials: [String: String] = [:]
    private var smsCommandPhone: [String: String] = [:]
    private let mirrorDecoder = H264VideoDecoder()
    private var realtimeConnections: [String: PeerConnection] = [:]
    private var realtimeFrames: [String: RealtimeFrameAssembly] = [:]
    private struct PendingRemoteDownload {
        var phoneId: String
        var folder: URL
        var completion: ((Error?) -> Void)?
        var securityScoped: Bool
        var isGallery: Bool
        var itemCount: Int
        var waitingSince: Date
    }
    private var pendingRemoteDownloadRequests: [String: PendingRemoteDownload] = [:]
    private var pendingRemoteDownloadTransfers: [String: PendingRemoteDownload] = [:]
    private var requestedGalleryThumbnails = Set<String>()
    private var mirrorRequestedAt = Date.distantPast
    private var mirrorFramesReceived = 0
    private let adb = BundledADBClient()
    let bluetoothCalls = BluetoothCalls()
    private let clipboardImageCache = NSCache<NSString, NSImage>()
    private let notificationIconCache = NSCache<NSString, NSImage>()
    private var callPopupController: CallPopupController?
    private var bluetoothObservation: AnyCancellable?
    var macId: String { identity?.id ?? "Unavailable" }
    var onlineName: String { connected.isEmpty ? "No phone connected" : phones.first(where: { connected.contains($0.id) })?.name ?? "Phone connected" }
    var localDeviceName: String { Host.current().localizedName ?? "This Mac" }
    init(storageDirectory: URL? = nil, pasteboard: NSPasteboard = .general, downloadsDirectory: URL? = nil, alertsEnabled: Bool = true, allowedNotificationPackages: Set<String>? = nil) {
        self.pasteboard = pasteboard; self.persistsPreferences = downloadsDirectory == nil; self.alertsEnabled = alertsEnabled; self.allowedNotificationPackages = allowedNotificationPackages
        receiveFolder = downloadsDirectory ?? Self.savedReceiveFolder()
        fileAlerts = UserDefaults.standard.object(forKey: "file-alerts") as? Bool ?? true
        fileSounds = UserDefaults.standard.object(forKey: "file-sounds") as? Bool ?? true
        clipboardQuotaBytes = (UserDefaults.standard.object(forKey: "clipboard-quota") as? NSNumber)?.int64Value ?? 1024 * 1024 * 1024
        super.init(); clipboardCount = pasteboard.changeCount
        if persistsPreferences && bluetoothCalls.selectedAddress != nil {
            DispatchQueue.main.async { [weak self] in self?.bluetoothCalls.restoreConnection() }
        }
        adbAvailable = adb.available
        mirrorDecoder.onFrame = { [weak self] frame in self?.mirrorFrame = frame }
        _ = receiveFolder.startAccessingSecurityScopedResource()
        do {
            history = try EncryptedHistory(directory: storageDirectory)
            let saved = try history!.load()
            notifications = SyncRules.prune(saved.notifications).filter { !["dev.androidsync.test", "dev.androidsync.fixture"].contains($0.package) }
            let retainedIconKeys = Set(notifications.flatMap { [$0.package, notificationIconKey(deviceId: $0.deviceId, package: $0.package)] })
            notificationAppIcons = saved.notificationAppIcons.filter { retainedIconKeys.contains($0.key) && $0.value.count <= 64 * 1024 && NSImage(data: $0.value) != nil }
            transfers = saved.transfers
            for i in transfers.indices where transfers[i].status == "Completed" { transfers[i].completionNotified = true }
            excluded = saved.excluded; clipboardPaused = saved.pausedClipboard; clearedAt = saved.clearedAt
            clipboardHistory = saved.clipboardHistory.sorted { ($0.logicalClock ?? 0,$0.createdAt) > ($1.logicalClock ?? 0,$1.createdAt) }
            clipboardTombstones = Set(saved.clipboardTombstones)
            pausedClipboardDevices = saved.pausedClipboardDevices
            askEveryTimeFiles = saved.askEveryTimeFiles
            smsThreads = saved.smsThreads; smsMessages = saved.smsMessages; contacts = saved.contacts; callHistory = saved.callHistory
            if let data = try Vault.get("trusted-phones") { phones = try JSONDecoder().decode([TrustedPhone].self, from: data) }
            // Migrate the original single-phone history without losing it. With
            // more than one historical phone there is no safe device inference,
            // so those old rows remain readable but intentionally non-actionable.
            if phones.count == 1, let phoneId = phones.first?.id {
                for index in notifications.indices where notifications[index].deviceId == nil {
                    let remoteId = notifications[index].remoteId ?? notifications[index].id
                    notifications[index].remoteId = remoteId
                    notifications[index].deviceId = phoneId
                    notifications[index].id = SyncRules.notificationIdentifier(deviceId: phoneId, remoteId: remoteId)
                }
            }
            identity = try MacIdentity()
            enforceClipboardQuota()
            if let latest = clipboardHistory.first { showClipboardRecord(latest) }
            let transport = LocalServer(identity: identity!); server = transport
            transport.onMessage = { [weak self] peer, message in Task { @MainActor in self?.handle(peer, message) } }
            transport.onClose = { [weak self] peer in Task { @MainActor in self?.disconnected(peer) } }
            transport.onStatus = { [weak self] state, port in Task { @MainActor in self?.status = state; self?.port = port; if port > 0 { self?.newInvitation() } } }
            try transport.start()
        } catch { self.error = error.localizedDescription; status = "Setup needs attention" }
        callPopupController = CallPopupController(model: self)
        bluetoothObservation = bluetoothCalls.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.callPopupController?.refresh() }
        }
        if alertsEnabled {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let dismiss = UNNotificationAction(identifier: "DISMISS_PHONE", title: "Dismiss on phone", options: [])
        var categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: "PHONE_REPLY", actions: [reply, dismiss], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: "PHONE", actions: [dismiss], intentIdentifiers: [], options: [.customDismissAction])
        ]
        for mask in 1..<16 {
            var callControls: [UNNotificationAction] = []
            if mask & 1 != 0 { callControls.append(UNNotificationAction(identifier: "CALL_ANSWER", title: "Answer", options: [])) }
            if mask & 2 != 0 { callControls.append(UNNotificationAction(identifier: "CALL_DECLINE", title: "Decline", options: [.destructive])) }
            if mask & 4 != 0 { callControls.append(UNNotificationAction(identifier: "CALL_MUTE", title: "Mute", options: [])) }
            if mask & 8 != 0 { callControls.append(UNTextInputNotificationAction(identifier: "CALL_DECLINE_MESSAGE", title: "Decline with Message", options: [.destructive], textInputButtonTitle: "Send", textInputPlaceholder: "Message")) }
            categories.insert(UNNotificationCategory(identifier: "PHONE_CALL_\(mask)", actions: callControls, intentIdentifiers: [], options: [.customDismissAction]))
        }
        center.setNotificationCategories(categories)
        refreshAlertSettings(requestIfNeeded: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resetClipboardCount() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.resetClipboardCount()
            if self?.bluetoothCalls.selectedAddress != nil, self?.bluetoothCalls.isConnected == false { self?.bluetoothCalls.restoreConnection() }
        } }
        save()
    }
    func requestAlerts(onGranted: (() -> Void)? = nil) {
        guard alertsEnabled else { return }
        if let onGranted { alertAuthorizationCallbacks.append(onGranted) }
        guard !requestingAlerts else { return }
        requestingAlerts = true; alertsStatus = "Requesting…"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.requestingAlerts = false
                let callbacks = self.alertAuthorizationCallbacks; self.alertAuthorizationCallbacks.removeAll()
                if let error { self.error = "Could not enable Mac alerts: \(error.localizedDescription)" }
                self.refreshAlertSettings()
                if granted { callbacks.forEach { $0() } }
            }
        }
    }
    func refreshAlertSettings(requestIfNeeded: Bool = false) {
        guard alertsEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                self.alertsAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self.alertsStatus = self.alertsAuthorized ? "Enabled" : settings.authorizationStatus == .denied ? "Disabled in macOS Settings" : "Permission needed"
                if requestIfNeeded && settings.authorizationStatus == .notDetermined { self.requestAlerts() }
            }
        }
    }
    func openNotificationSettings() { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
    func refreshPhoneNotifications() { controls.values.forEach { $0.send(WireMessage("notifications.refresh")) }; refreshAlertSettings() }
    func startMirroring(phoneId: String, control: Bool) {
        guard let peer = controls[phoneId] else { error = "Reconnect the Android device before starting mirroring."; return }
        stopMirroring(sendStop: true)
        let session = UUID().uuidString
        mirrorPhoneId = phoneId; mirrorSessionId = session; mirrorControlEnabled = control; mirrorFrame = nil; mirrorWidth = 0; mirrorHeight = 0; mirrorAppliedBitrate = nil
        mirrorStatus = "Waiting for fresh Android screen-capture consent…"; mirrorRequestedAt = Date()
        peer.send(WireMessage("stream.start",["sessionId": session,"kind": "screen","control": control,"bitrate": mirrorBitrate],capability: "realtime"))
    }
    func stopMirroring(sendStop: Bool = true) {
        if sendStop, let phoneId = mirrorPhoneId, let sessionId = mirrorSessionId {
            controls[phoneId]?.send(WireMessage("stream.stop",["sessionId": sessionId],capability: "realtime"))
            realtimeConnections[phoneId]?.send(WireMessage("stream.stop",["sessionId": sessionId],capability: "realtime"))
        }
        if let phoneId = mirrorPhoneId { realtimeConnections.removeValue(forKey: phoneId)?.close() }
        realtimeFrames.removeAll(); mirrorFramesReceived = 0; mirrorDecoder.reset(); mirrorFrame = nil; mirrorWidth = 0; mirrorHeight = 0; mirrorSessionId = nil; mirrorControlEnabled = false; mirrorAppliedBitrate = nil
        if mirrorPhoneId != nil { mirrorStatus = "Screen sharing stopped." }
    }
    func configureMirrorBitrate(_ value: Int) {
        mirrorBitrate = min(max(value,1_000_000),12_000_000)
        guard let phoneId = mirrorPhoneId, let sessionId = mirrorSessionId else { return }
        let command = WireMessage("stream.configure",["sessionId": sessionId,"bitrate": mirrorBitrate],capability: "realtime")
        if let realtime = realtimeConnections[phoneId] { realtime.send(command) }
        else { controls[phoneId]?.send(command) }
    }
    func remoteTap(x: Double, y: Double) { sendRemoteInput(["action": "tap","x": x,"y": y]) }
    func remoteSwipe(x: Double, y: Double, endX: Double, endY: Double, duration: Int = 300) { sendRemoteInput(["action": "swipe","x": x,"y": y,"endX": endX,"endY": endY,"duration": duration]) }
    func remoteNavigation(_ action: String) { guard ["back","home","recents","notifications"].contains(action) else { return }; sendRemoteInput(["action": action]) }
    func remoteText(_ text: String, paste: Bool = false) { guard !text.isEmpty else { return }; sendRemoteInput(["action": paste ? "paste" : "text","text": String(text.prefix(64 * 1024))]) }
    private func sendRemoteInput(_ body: [String: Any]) {
        guard mirrorControlEnabled, let phoneId = mirrorPhoneId, let sessionId = mirrorSessionId, let peer = realtimeConnections[phoneId] else { remoteControlStatus = "Remote control is unavailable for this session."; return }
        var payload = body; payload["sessionId"] = sessionId; remoteControlStatus = "Sending control action…"
        peer.send(WireMessage("control.input",payload,capability: "realtime"))
    }
    func sendMediaCommand(phoneId: String, action: String) {
        guard let peer = controls[phoneId], let media = mediaStates[phoneId], media.actions.contains(action) else { return }
        peer.send(WireMessage("media.command",["action": action,"packageName": media.packageName],capability: "media"))
    }
    func refreshMedia(phoneId: String? = nil) {
        if let phoneId { controls[phoneId]?.send(WireMessage("media.refresh",capability: "media")) }
        else { controls.values.forEach { $0.send(WireMessage("media.refresh",capability: "media")) } }
    }
    func adbPair(endpoint: String, code: String) { Task { do { adbStatus = try await adb.pair(endpoint: endpoint,code: code) } catch { adbStatus = error.localizedDescription } } }
    func adbConnect(endpoint: String) { Task { do { adbStatus = try await adb.connect(endpoint: endpoint) } catch { adbStatus = error.localizedDescription } } }
    func adbDisconnect(endpoint: String) { Task { do { adbStatus = try await adb.disconnect(endpoint: endpoint) } catch { adbStatus = error.localizedDescription } } }
    func refreshMessages(phoneId: String? = nil) {
        let targets = phoneId.flatMap { controls[$0].map { [$0] } } ?? Array(controls.values)
        for peer in targets {
            guard let id = peer.phoneId else { continue }
            smsStatus[id] = "Refreshing carrier SMS…"
            peer.send(WireMessage("sms.refresh",capability: "sms")); peer.send(WireMessage("contacts.refresh",capability: "sms"))
        }
    }
    func loadCallHistory(phoneId: String, reset: Bool = false) {
        guard let peer = controls[phoneId], !pendingCallPages.values.contains(where: { $0.phoneId == phoneId }) else { return }
        if reset { callHistory.removeAll { $0.deviceId == phoneId }; callHistoryHasMore[phoneId] = true; save() }
        guard callHistoryHasMore[phoneId] != false else { return }
        let offset = callHistory.filter { $0.deviceId == phoneId }.count
        let request = WireMessage("calls.page",["offset": offset],capability: "calls")
        pendingCallPages[request.id] = (phoneId,offset); callHistoryLoading = true; callHistoryStatus[phoneId] = "Loading call history…"
        peer.send(request)
    }
    func dial(phoneId: String, number: String) {
        let candidate = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let peer = controls[phoneId] else { dialStatus[phoneId] = "Android is offline."; return }
        guard candidate.count >= 3 && candidate.count <= 40 && candidate.allSatisfy({ $0.isNumber || "+*#() -.".contains($0) }) else { dialStatus[phoneId] = "Enter a valid phone number."; return }
        let request = WireMessage("calls.dial",["number": candidate],capability: "calls")
        pendingDials[request.id] = phoneId; dialStatus[phoneId] = "Sending dial request…"; peer.send(request)
    }
    @discardableResult func sendSMS(phoneId: String, address: String, body: String) -> String? {
        let destination = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let peer = controls[phoneId] else { error = "Reconnect the Android device before sending."; return nil }
        guard !destination.isEmpty, !content.isEmpty, content.count <= 10_000 else { error = "Enter a phone number and a message of at most 10,000 characters."; return nil }
        let command = WireMessage("sms.send",["address": destination,"body": content],capability: "sms")
        smsCommandPhone[command.id] = phoneId; smsCommandStates[command.id] = "sending"; smsCommandDetails[command.id] = "Sending through Android…"
        peer.send(command); return command.id
    }
    func clearMessageCache(phoneId: String? = nil) {
        smsThreads.removeAll { phoneId == nil || $0.deviceId == phoneId }
        smsMessages.removeAll { phoneId == nil || $0.deviceId == phoneId }
        contacts.removeAll { phoneId == nil || $0.deviceId == phoneId }
        callHistory.removeAll { phoneId == nil || $0.deviceId == phoneId }
        if let phoneId { callHistoryHasMore.removeValue(forKey: phoneId) } else { callHistoryHasMore.removeAll() }
        save()
    }
    func testMacAlert() {
        guard alertsEnabled else { return }
        if alertsAuthorized { showSimpleAlert("Android Sync test", text: "Mac notification alerts are working.", sound: fileSounds) }
        else { requestAlerts { [weak self] in guard let self else { return }; self.showSimpleAlert("Android Sync test", text: "Mac notification alerts are working.", sound: self.fileSounds) } }
    }
    private static var defaultReceiveFolder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Android Sync", isDirectory: true) }
    private static func savedReceiveFolder() -> URL {
        guard let data = UserDefaults.standard.data(forKey: "receive-folder") else { return defaultReceiveFolder }
        var stale = false
        if let scoped = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return scoped }
        return (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? defaultReceiveFolder
    }
    func chooseReceiveFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Save files here"
        if panel.runModal() == .OK, let url = panel.url { setReceiveFolder(url) }
    }
    func setReceiveFolder(_ url: URL) {
        do {
            guard url.isFileURL else { throw StoreError(detail: "Choose a local folder.") }
            let bookmark: Data
            if let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) { bookmark = scoped }
            else { bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) }
            receiveFolder.stopAccessingSecurityScopedResource()
            receiveFolder = url
            _ = receiveFolder.startAccessingSecurityScopedResource()
            if persistsPreferences { UserDefaults.standard.set(bookmark, forKey: "receive-folder") }
        } catch { self.error = "Could not save the receiving folder: \(error.localizedDescription)" }
    }
    func resetReceiveFolder() { receiveFolder.stopAccessingSecurityScopedResource(); receiveFolder = Self.defaultReceiveFolder; _ = receiveFolder.startAccessingSecurityScopedResource(); if persistsPreferences { UserDefaults.standard.removeObject(forKey: "receive-folder") } }
    func saveFileAlertPreferences() { if persistsPreferences { UserDefaults.standard.set(fileAlerts, forKey: "file-alerts"); UserDefaults.standard.set(fileSounds, forKey: "file-sounds") } }
    func newInvitation() {
        guard let identity, port > 0 else { return }
        do {
            secret = try Vault.random(32).base64EncodedString(); invitationExpires = Date().addingTimeInterval(300)
            let hosts = LocalServer.localAddresses()
            let object: [String: Any] = ["v": 1, "macId": identity.id, "name": Host.current().localizedName ?? "Mac", "hosts": hosts, "port": Int(port), "fingerprint": identity.fingerprint, "secret": secret, "expires": Int64(invitationExpires.timeIntervalSince1970 * 1000)]
            invitation = String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        } catch { self.error = error.localizedDescription }
    }
    func revoke(_ phone: TrustedPhone) {
        phones.removeAll { $0.id == phone.id }
        askEveryTimeFiles.remove(phone.id)
        if remoteStoragePhoneId == phone.id { remoteStoragePhoneId = nil; remoteStorageEntries = []; remoteStorageMessage = nil }
        if galleryPhoneId == phone.id { galleryPhoneId = nil; galleryEntries = []; galleryMessage = nil }
        smsThreads.removeAll { $0.deviceId == phone.id }; smsMessages.removeAll { $0.deviceId == phone.id }; contacts.removeAll { $0.deviceId == phone.id }
        persistPhones()
        save()
        let control = controls[phone.id]
        control?.sendAndClose(WireMessage("device.revoked"))
        for peer in server?.peers.values.filter({ $0.phoneId == phone.id && $0.id != control?.id }) ?? [] { peer.close() }
    }
    func setAskEveryTimeFiles(_ phoneId: String, _ value: Bool) {
        if value { askEveryTimeFiles.insert(phoneId) } else { askEveryTimeFiles.remove(phoneId) }
        save()
    }
    private func persistPhones() {
        do { try Vault.put("trusted-phones", JSONEncoder().encode(phones)) } catch { self.error = error.localizedDescription }
    }
    private func authenticate(_ peer: PeerConnection, _ message: WireMessage) {
        let b = message.body
        guard ["auth.request", "pair.request"].contains(message.type), let phoneId = b["phoneId"] as? String, UUID(uuidString: phoneId) != nil,
              let stream = b["stream"] as? String, ["control", "file", "bulk", "realtime"].contains(stream), let signature = b["signature"] as? String else { peer.close(); return }
        let publicKey: String
        if message.type == "pair.request" {
            guard stream == "control", Date() < invitationExpires, !secret.isEmpty, b["secret"] as? String == secret,
                  let key = b["publicKey"] as? String, let name = b["name"] as? String, name.count <= 200 else { peer.send(WireMessage("auth.error", ["reason": "Invitation expired or invalid"])); peer.close(); return }
            publicKey = key
        } else {
            guard let phone = phones.first(where: { $0.id == phoneId }) else { peer.close(); return }; publicKey = phone.publicKey
        }
        guard MacIdentity.verify(publicKey: publicKey, signature: signature, message: SyncRules.signaturePayload(macId: macId, nonce: peer.nonce, stream: stream, phoneId: phoneId)) else { peer.close(); return }
        if message.type == "pair.request" {
            phones.removeAll { $0.id == phoneId }; phones.append(TrustedPhone(id: phoneId, name: b["name"] as? String ?? "Android", publicKey: publicKey)); persistPhones()
            secret = ""; invitation = ""; invitationExpires = .distantPast
        }
        let offeredVersions = (b["versions"] as? [NSNumber])?.map(\.intValue) ?? [1]
        let selectedProtocol = offeredVersions.contains(2) ? 2 : 1
        peer.phoneId = phoneId; peer.stream = stream == "file" ? "bulk" : stream; peer.protocolVersion = selectedProtocol
        peer.send(WireMessage("auth.ok", ["macId": macId, "name": Host.current().localizedName ?? "Mac", "protocol": selectedProtocol, "lanes": ["control", "bulk", "realtime"], "capabilities": ["notifications", "reply", "call.controls", "clipboard.text", "clipboard.image", "links", "files.resume", "files.storage", "files.gallery", "screen.h264", "remote.control", "media.controls"], "capabilitySet": ["capabilities": [
            ["id": "notifications", "state": "enabled"], ["id": "clipboard", "state": "enabled"], ["id": "files", "state": "enabled"],
            ["id": "sms", "state": "permission_required"], ["id": "screen", "state": "supported"], ["id": "control", "state": "permission_required"], ["id": "media", "state": "supported"],
            ["id": "callControls", "state": "enabled", "reason": "Available when the active Android call notification exposes controls"],
            ["id": "calls", "state": "unsupported", "reason": "Call audio remains on Android"]
        ]], "calls": false], version: 1))
        peer.authenticated = true
        if stream == "control" {
            let old = controls.updateValue(peer, forKey: phoneId); old?.close(); connected.insert(phoneId)
            for transfer in transfers where transfer.phoneId == phoneId && !["Completed", "Declined", "Cancelled"].contains(transfer.status) {
                if transfer.incoming && transfer.accepted { peer.send(WireMessage("file.accept", ["transferId": transfer.id, "offsets": offsets(for: transfer)])) }
                else if !transfer.incoming { peer.send(WireMessage("file.offer", WireMessage.object(transfer.offer))) }
            }
            for targetId in clipboardTombstones { peer.send(WireMessage("clipboard.delete", ["targetId": targetId, "historical": true])) }
            peer.send(WireMessage("media.refresh",capability: "media"))
        }
    }
    private func handle(_ peer: PeerConnection, _ message: WireMessage) {
        guard peer.authenticated else { authenticate(peer, message); return }
        guard let phoneId = peer.phoneId, phones.contains(where: { $0.id == phoneId }) else { peer.close(); return }
        if peer.stream == "bulk" { handleFile(peer, message); return }
        if peer.stream == "realtime" { handleRealtime(peer, message); return }
        guard controls[phoneId]?.id == peer.id else { peer.close(); return }
        if message.type == "ping" { peer.send(WireMessage("pong", id: message.id)); return }
        guard seen.insert(message.id) else { return }
        let b = message.body
        switch message.type {
        case "phone.status":
            let previousMessagesAccess = phoneStatuses[phoneId]?.messagesAccess
            let capabilityRows = ((b["capabilitySet"] as? [String: Any])?["capabilities"] as? [[String: Any]]) ?? []
            let capabilities = Dictionary(uniqueKeysWithValues: capabilityRows.compactMap { row -> (String, String)? in
                guard let id = row["id"] as? String, let state = row["state"] as? String else { return nil }; return (id,state)
            })
            phoneStatuses[phoneId] = PhoneSyncStatus(
                notificationAccess: b["notificationAccess"] as? Bool ?? false,
                listenerConnected: b["listenerConnected"] as? Bool ?? false,
                clipboardMode: b["clipboardMode"] as? String ?? "foreground",
                messagesAccess: b["messagesAccess"] as? Bool,
                messagesPermissions: b["messagesPermissions"] as? Bool,
                protocolVersion: (b["protocol"] as? NSNumber)?.intValue ?? message.version,
                lanes: b["lanes"] as? [String] ?? ["control"],
                capabilities: capabilities
            )
            if previousMessagesAccess != true && phoneStatuses[phoneId]?.messagesAccess == true {
                loadCallHistory(phoneId: phoneId, reset: true)
            }
        case "device.unpair":
            if let phone = phones.first(where: { $0.id == phoneId }) { revoke(phone) }
        case "notifications.begin": snapshotKeys[phoneId] = []
        case "notification.upsert":
            guard var item = try? message.decode(PhoneNotification.self), item.id.count <= 512, item.text.count <= 16000, item.title.count <= 2000,
                  item.callerName?.count ?? 0 <= 300, item.callerNumber?.count ?? 0 <= 100, item.callerImage?.utf8.count ?? 0 <= 90_000,
                  item.callActions?.count ?? 0 <= 6, item.callActions?.allSatisfy({ ["answer","decline","mute","declineMessage"].contains($0.kind) && $0.id.count <= 64 && $0.title.count <= 200 }) ?? true else { return }
            if let icon = item.appIcon { acceptNotificationAppIcon(icon, package: item.package, deviceId: phoneId) }
            item.appIcon = nil
            let remoteId = item.id
            item.remoteId = remoteId; item.deviceId = phoneId
            item.id = SyncRules.notificationIdentifier(deviceId: phoneId, remoteId: remoteId)
            snapshotKeys[phoneId, default: []].insert(item.id)
            lastNotificationReceived = Date()
            item.timestamp = min(item.timestamp, Int64(Date().timeIntervalSince1970 * 1000) + 60000)
            guard item.timestamp > clearedAt, !excluded.contains(item.package), allowedNotificationPackages?.contains(item.package) != false else { return }
            let previous = notifications.first { $0.id == item.id }
            let show = b["snapshot"] as? Bool != true && previous?.localDismissed != true && (previous?.text != item.text || previous?.title != item.title)
            SyncRules.upsert(item, into: &notifications); notifications = SyncRules.prune(notifications)
            if show { showNotification(item) }; save(); refreshCallPopup()
        case "notifications.end":
            let activeKeys = snapshotKeys.removeValue(forKey: phoneId) ?? []
            for index in notifications.indices where notifications[index].deviceId == phoneId && !activeKeys.contains(notifications[index].id) { notifications[index].active = false }
            save(); refreshCallPopup()
        case "notification.remove":
            if let remoteId = b["key"] as? String {
                let key = SyncRules.notificationIdentifier(deviceId: phoneId, remoteId: remoteId)
                if let index = notifications.firstIndex(where: { $0.id == key }) {
                    notifications[index].active = false; if alertsEnabled { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key]) }; save(); refreshCallPopup()
                }
            }
        case "action.result":
            guard let commandId = (b["commandId"] as? String) ?? message.replyTo, commandPhone[commandId] == phoneId else { return }
            recordActionResult(commandId, state: b["state"] as? String ?? "failed", reason: b["reason"] as? String)
        case "clipboard.update":
            guard !clipboardPaused, let text = b["text"] as? String, text.utf8.count <= 65536 else { return }
            let revision = (b["revision"] as? NSNumber)?.int64Value ?? 0
            let session = b["session"] as? String ?? "v2"
            let previousRevision = clipboardRevisions[phoneId]
            if message.version == 1 {
                guard previousRevision?.session != session || revision > (previousRevision?.revision ?? 0) else { return }
            }
            clipboardRevisions[phoneId] = (session,revision)
            let eventId = b["clipId"] as? String ?? message.id
            guard !clipboardTombstones.contains(eventId) else { return }
            let origin = b["origin"] as? String ?? phones.first(where: { $0.id == phoneId })?.name ?? "Android"
            let sourceApp = b["sourceApp"] as? String ?? "Source unavailable"
            let originId = b["originDeviceId"] as? String ?? message.originDeviceId ?? phoneId
            guard !pausedClipboardDevices.contains(originId) else { return }
            let clock = (b["acceptedClock"] as? NSNumber)?.int64Value ?? message.clock ?? revision
            let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
            let createdMillis = min((b["createdAt"] as? NSNumber)?.int64Value ?? message.sentAt ?? nowMillis,nowMillis + 60_000)
            let createdAt = Date(timeIntervalSince1970: Double(createdMillis) / 1000)
            let deviceName = originId == phoneId ? phones.first(where: { $0.id == phoneId })?.name ?? origin : origin
            recordClipboardText(text,id: eventId,deviceId: originId,deviceName: deviceName,origin: origin,sourceApp: sourceApp,logicalClock: clock,createdAt: createdAt,contentHash: b["contentHash"] as? String)
            let newer = clock > lastLiveClipboardOrder.clock || (clock == lastLiveClipboardOrder.clock && originId > lastLiveClipboardOrder.origin)
            if originId != macId, newer, b["historical"] as? Bool != true {
                lastLiveClipboardOrder = (clock,originId)
                clipboardText = text; clipboardOrigin = origin; clipboardSourceApp = sourceApp; clipboardImage = nil
                pasteboard.clearContents(); pasteboard.setString(text, forType: .string); clipboardCount = pasteboard.changeCount
            }
            for (id, control) in controls where id != phoneId { control.send(message) }
        case "clipboard.delete":
            guard let targetId = b["targetId"] as? String, targetId.count <= 128 else { return }
            clipboardTombstones.insert(targetId)
            removeClipboardRecord(id: targetId)
            for (id, control) in controls where id != phoneId { control.send(message) }
        case "link.share":
            if let link = b["url"] as? String, SyncRules.validWebURL(link) != nil { receivedLinks.insert(link, at: 0); receivedLinks = Array(receivedLinks.prefix(30)); showSimpleAlert("Link received", text: "Open Android Sync to view it.") }
        case "file.offer":
            guard let offer = try? message.decode(FileOffer.self), (try? offer.validate()) != nil else { peer.close(); return }
            if let existing = transfers.first(where: { $0.id == offer.id }) {
                guard existing.phoneId == phoneId, existing.offer == offer, existing.incoming else { peer.close(); return }
                if existing.accepted { peer.send(WireMessage("file.accept", ["transferId": offer.id, "offsets": offsets(for: existing)])) }
                else if ["Declined", "Cancelled"].contains(existing.status) { peer.send(WireMessage("file.decline", ["transferId": offer.id])) }
            } else {
                let pending = pendingRemoteDownloadTransfers[offer.id]
                // Downloads started by dragging or pressing Download are already
                // explicit user actions. "Ask every time" applies only to an
                // unsolicited batch pushed from Android.
                let ask = pending == nil && askEveryTimeFiles.contains(phoneId)
                var record = TransferRecord(offer: offer, phoneId: phoneId, incoming: true, status: ask ? "Awaiting your acceptance" : "Preparing to receive")
                record.receiveFolderPath = pending?.folder.path
                transfers.insert(record, at: 0); save()
                if ask { showSimpleAlert("Files from \(onlineName)", text: "Open Android Sync to accept or decline this transfer.") }
                else {
                    if pending?.isGallery == true { galleryMessage = "Downloading \(offer.files.count) \(offer.files.count == 1 ? "item" : "items")…" }
                    else if pending != nil { remoteStorageMessage = "Downloading \(offer.files.count) \(offer.files.count == 1 ? "file" : "files")…" }
                    acceptTransfer(offer.id)
                }
            }
        case "file.accept":
            if let id = b["transferId"] as? String, let i = transfers.firstIndex(where: { $0.id == id && !$0.incoming && $0.phoneId == phoneId && $0.status != "Cancelled" }) { transfers[i].accepted = true; transfers[i].status = "Sending"; transfers[i].startedAt = transfers[i].startedAt ?? Date(); save() }
        case "file.decline", "file.cancel":
            if let id = b["transferId"] as? String, let i = transfers.firstIndex(where: { $0.id == id && $0.phoneId == phoneId }) { transfers[i].status = message.type == "file.decline" ? "Declined" : "Cancelled"; transfers[i].accepted = false; finishPendingRemoteDownload(id,error: StoreError(detail: transfers[i].status)); closeTransferStreams(id); save() }
        case "file.complete":
            if let id = b["transferId"] as? String, let i = transfers.firstIndex(where: { $0.id == id && $0.phoneId == phoneId && !$0.incoming && $0.accepted }) { transfers[i].status = "Completed"; transfers[i].bytes = transfers[i].total; transfers[i].speedBytesPerSecond = 0; notifyTransferCompletion(id); save() }
        case "storage.list.result":
            guard remoteStoragePhoneId == phoneId, let listing = try? message.decode(StorageListing.self) else { return }
            remoteStorageLoading = false
            if listing.state == "accepted" {
                let offset = listing.offset ?? 0
                remoteStoragePath = listing.path; remoteStorageParent = listing.parent
                if offset == 0 { remoteStorageEntries = listing.entries }
                else { remoteStorageEntries.append(contentsOf: listing.entries.filter { item in !remoteStorageEntries.contains(where: { $0.id == item.id }) }) }
                remoteStorageNextOffset = listing.nextOffset ?? remoteStorageEntries.count
                remoteStorageHasMore = listing.hasMore ?? false
                remoteStorageMessage = listing.entries.isEmpty ? "This folder is empty." : nil
            } else {
                remoteStorageMessage = listing.reason ?? "Android shared storage is unavailable."
                remoteStorageEntries = []
                remoteStorageHasMore = false
            }
        case "storage.download.result":
            handleRemoteDownloadResult(body: b,isGallery: false)
        case "gallery.list.result":
            guard galleryPhoneId == phoneId, let listing = try? message.decode(MediaListing.self) else { return }
            galleryLoading = false
            if listing.state == "accepted" {
                if listing.cursor == 0 { galleryEntries = listing.entries }
                else { galleryEntries.append(contentsOf: listing.entries.filter { item in !galleryEntries.contains(where: { $0.id == item.id }) }) }
                galleryNextCursor = listing.nextCursor ?? galleryEntries.count
                galleryHasMore = listing.hasMore
                galleryMessage = galleryEntries.isEmpty ? "No photos or videos were found on this device." : nil
            } else { galleryEntries = []; galleryHasMore = false; galleryMessage = listing.reason ?? "Android media library is unavailable." }
        case "gallery.thumbnail.result":
            guard galleryPhoneId == phoneId, let mediaId = b["mediaId"] as? String else { return }
            let key = galleryThumbnailKey(phoneId: phoneId,mediaId: mediaId)
            guard b["state"] as? String == "accepted", let encoded = b["data"] as? String,
                  let data = Data(base64Encoded: encoded), data.count <= 128 * 1024, NSImage(data: data) != nil else {
                requestedGalleryThumbnails.remove(key)
                return
            }
            galleryThumbnails[key] = data
        case "gallery.download.result":
            handleRemoteDownloadResult(body: b,isGallery: true)
        case "sms.snapshot.begin":
            pendingSmsThreads[phoneId] = []; pendingSmsMessages[phoneId] = []; smsStatus[phoneId] = "Refreshing carrier SMS…"
        case "sms.thread":
            guard var item = try? message.decode(SmsThreadRecord.self), item.id.count <= 128, item.address.count <= 200, item.snippet.count <= 240 else { return }
            item.id = "\(phoneId)::\(item.id)"; item.deviceId = phoneId
            pendingSmsThreads[phoneId,default: []].append(item)
        case "sms.message":
            guard var item = try? message.decode(SmsMessageRecord.self), item.id.count <= 128, item.threadId.count <= 128, item.address.count <= 200, item.body.count <= 16_000 else { return }
            item.id = "\(phoneId)::\(item.id)"; item.threadId = "\(phoneId)::\(item.threadId)"; item.deviceId = phoneId
            pendingSmsMessages[phoneId,default: []].append(item)
        case "sms.snapshot.end":
            guard let newThreads = pendingSmsThreads.removeValue(forKey: phoneId), let newMessages = pendingSmsMessages.removeValue(forKey: phoneId) else { return }
            smsThreads = (smsThreads.filter { $0.deviceId != phoneId } + newThreads).sorted { $0.timestamp > $1.timestamp }
            smsMessages = (smsMessages.filter { $0.deviceId != phoneId } + newMessages).sorted { $0.timestamp < $1.timestamp }
            smsStatus[phoneId] = "Carrier SMS synchronized"; save()
        case "sms.snapshot.error":
            smsStatus[phoneId] = b["reason"] as? String ?? "Carrier SMS is unavailable."
        case "contacts.snapshot.begin":
            pendingContacts[phoneId] = []
        case "contact":
            guard var item = try? message.decode(ContactRecord.self), item.id.count <= 128, item.name.count <= 300, item.phones.count <= 20 else { return }
            item.id = "\(phoneId)::\(item.id)"; item.deviceId = phoneId
            pendingContacts[phoneId,default: []].append(item)
        case "contacts.snapshot.end":
            guard let newContacts = pendingContacts.removeValue(forKey: phoneId) else { return }
            contacts = (contacts.filter { $0.deviceId != phoneId } + newContacts).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            save()
        case "contacts.snapshot.error":
            smsStatus[phoneId] = b["reason"] as? String ?? "Contacts are unavailable."
        case "calls.page.result":
            guard let requestId = message.replyTo, let pending = pendingCallPages.removeValue(forKey: requestId), pending.phoneId == phoneId,
                  (b["offset"] as? NSNumber)?.intValue == pending.offset, let raw = b["rows"] as? [[String: Any]], raw.count <= 100,
                  let data = try? JSONSerialization.data(withJSONObject: raw), var rows = try? JSONDecoder().decode([CallHistoryRecord].self,from: data),
                  rows.allSatisfy({ $0.id.count <= 128 && $0.number.count <= 100 && ($0.name?.count ?? 0) <= 300 && $0.timestamp >= 0 && $0.duration >= 0 }) else { return }
            rows = rows.map { var row = $0; row.id = "\(phoneId)::\(row.id)"; row.deviceId = phoneId; return row }
            let existing = Set(callHistory.map(\.id))
            callHistory.append(contentsOf: rows.filter { !existing.contains($0.id) })
            callHistory.sort { $0.timestamp > $1.timestamp }
            callHistoryHasMore[phoneId] = b["hasMore"] as? Bool ?? false
            callHistoryStatus[phoneId] = "\(callHistory.filter { $0.deviceId == phoneId }.count) calls loaded"
            callHistoryLoading = !pendingCallPages.isEmpty; save()
        case "calls.page.error":
            if let requestId = message.replyTo, let pending = pendingCallPages.removeValue(forKey: requestId), pending.phoneId == phoneId {
                callHistoryLoading = !pendingCallPages.isEmpty; callHistoryStatus[phoneId] = b["reason"] as? String ?? "Call history unavailable."
            }
        case "calls.dial.result":
            if let requestId = message.replyTo, pendingDials.removeValue(forKey: requestId) == phoneId {
                dialStatus[phoneId] = b["reason"] as? String ?? "Android did not confirm dialing."
            }
        case "sms.send.result":
            guard let commandId = message.replyTo, smsCommandPhone[commandId] == phoneId else { return }
            let state = b["state"] as? String ?? "failed"
            smsCommandStates[commandId] = state; smsCommandDetails[commandId] = b["reason"] as? String ?? (state == "accepted" ? "Android accepted the carrier SMS request." : "SMS failed.")
        case "sms.access.revoked":
            smsThreads.removeAll { $0.deviceId == phoneId }; smsMessages.removeAll { $0.deviceId == phoneId }; contacts.removeAll { $0.deviceId == phoneId }
            callHistory.removeAll { $0.deviceId == phoneId }; callHistoryHasMore.removeValue(forKey: phoneId)
            smsStatus[phoneId] = b["reason"] as? String ?? "Messages access was revoked on Android."
            save()
        case "stream.result":
            let session = b["sessionId"] as? String
            let state = b["state"] as? String ?? "failed"; let detail = b["reason"] as? String ?? state
            if session == mirrorSessionId {
                mirrorStatus = detail
                if let value = (b["bitrate"] as? NSNumber)?.intValue { mirrorAppliedBitrate = value }
                if ["failed","stopped"].contains(state) { stopMirroring(sendStop: false); mirrorStatus = detail }
            }
        case "stream.configure.result":
            if b["sessionId"] as? String == mirrorSessionId {
                if let value = (b["appliedBitrate"] as? NSNumber)?.intValue { mirrorAppliedBitrate = value }
                if b["state"] as? String == "failed" { mirrorStatus = b["reason"] as? String ?? "Android rejected the bitrate change." }
            }
        case "media.state":
            if b["active"] as? Bool == false { mediaStates.removeValue(forKey: phoneId) }
            else if let state = try? message.decode(MediaStateRecord.self), state.packageName.count <= 300, state.actions.count <= 8 { mediaStates[phoneId] = state }
        case "media.result":
            if b["state"] as? String == "failed" { error = b["reason"] as? String ?? "Android rejected the media command." }
        default: break
        }
    }
    private func handleRealtime(_ peer: PeerConnection, _ message: WireMessage) {
        guard let phoneId = peer.phoneId else { peer.close(); return }
        let b = message.body
        switch message.type {
        case "stream.offer":
            let offeredKind = b["kind"] as? String ?? ""
            let offeredSession = b["sessionId"] as? String
            let screenMatch = offeredKind == "screen" && b["codec"] as? String == "h264" && offeredSession == mirrorSessionId && mirrorPhoneId == phoneId && Date().timeIntervalSince(mirrorRequestedAt) < 180
            guard screenMatch else {
                peer.sendAndClose(WireMessage("stream.result",id: message.id,["sessionId": offeredSession ?? "","state": "failed","reason": "No matching recent Mac realtime request is active."],replyTo: message.id)); return
            }
            realtimeConnections.removeValue(forKey: phoneId)?.close(); realtimeConnections[phoneId] = peer
            mirrorControlEnabled = b["control"] as? Bool == true
            mirrorStatus = mirrorControlEnabled ? "Streaming with remote control" : "Streaming · view only"
            peer.send(WireMessage("stream.result",id: message.id,["sessionId": offeredSession!,"state": "accepted"],capability: "realtime",replyTo: message.id))
        case "stream.config":
            guard realtimeConnections[phoneId]?.id == peer.id else { peer.close(); return }
            guard let first = b["csd0"] as? String, let csd0 = Data(base64Encoded: first) else { return }
            let csd1 = (b["csd1"] as? String).flatMap { Data(base64Encoded: $0) }
            guard b["sessionId"] as? String == mirrorSessionId else { return }
            mirrorWidth = (b["width"] as? NSNumber)?.intValue ?? 0; mirrorHeight = (b["height"] as? NSNumber)?.intValue ?? 0
            mirrorDecoder.configure(csd0: csd0,csd1: csd1)
        case "stream.video":
            guard realtimeConnections[phoneId]?.id == peer.id else { peer.close(); return }
            let frameSession = b["sessionId"] as? String
            guard frameSession == mirrorSessionId, let frameId = b["frameId"] as? String, frameId.count <= 128,
                  let encoded = b["data"] as? String, let data = Data(base64Encoded: encoded), data.count <= 128 * 1024 else { return }
            let count = (b["count"] as? NSNumber)?.intValue ?? 0; let index = (b["index"] as? NSNumber)?.intValue ?? -1
            if realtimeFrames[frameId] == nil { realtimeFrames[frameId] = RealtimeFrameAssembly(count: count,presentationTime: (b["pts"] as? NSNumber)?.int64Value ?? 0,keyFrame: b["key"] as? Bool ?? false) }
            guard var frame = realtimeFrames[frameId], frame.count == count else { realtimeFrames.removeValue(forKey: frameId); return }
            if let complete = frame.append(index: index,data: data) {
                realtimeFrames.removeValue(forKey: frameId)
                mirrorDecoder.decode(complete,presentationTime: frame.presentationTime,keyFrame: frame.keyFrame)
            }
            else { realtimeFrames[frameId] = frame }
            if realtimeFrames.count > 12 { realtimeFrames.removeValue(forKey: realtimeFrames.keys.first!) }
            mirrorFramesReceived += 1
            if mirrorFramesReceived % 30 == 0, let frameSession { peer.send(WireMessage("stream.feedback",["sessionId": frameSession,"backlog": realtimeFrames.count],capability: "realtime")) }
        case "control.result":
            guard realtimeConnections[phoneId]?.id == peer.id else { peer.close(); return }
            remoteControlStatus = b["reason"] as? String ?? (b["state"] as? String ?? "Control result received.")
        case "stream.result":
            let detail = b["reason"] as? String ?? (b["state"] as? String ?? "Realtime stream updated.")
            if let value = (b["bitrate"] as? NSNumber)?.intValue { mirrorAppliedBitrate = value }
            guard b["sessionId"] as? String == mirrorSessionId else { return }
            mirrorStatus = detail
        case "stream.configure.result":
            guard b["sessionId"] as? String == mirrorSessionId else { return }
            if let value = (b["appliedBitrate"] as? NSNumber)?.intValue { mirrorAppliedBitrate = value }
            let state = b["state"] as? String ?? "accepted"
            if state == "failed" { mirrorStatus = b["reason"] as? String ?? "Android rejected the bitrate change." }
        default: break
        }
    }
    private func disconnected(_ peer: PeerConnection) {
        if peer.stream == "realtime", let id = peer.phoneId {
            if realtimeConnections[id]?.id == peer.id {
                realtimeConnections.removeValue(forKey: id)
                if mirrorPhoneId == id && mirrorSessionId != nil { mirrorStatus = "Screen stream disconnected. Start a new session to obtain fresh Android consent."; mirrorDecoder.reset(); mirrorFrame = nil; mirrorSessionId = nil }
            }
            return
        }
        guard let id = peer.phoneId, controls[id]?.id == peer.id else { return }
        controls.removeValue(forKey: id); connected.remove(id)
        phoneStatuses.removeValue(forKey: id)
        mediaStates.removeValue(forKey: id)
        if mirrorPhoneId == id { stopMirroring(sendStop: false); mirrorStatus = "Phone disconnected. Start a new session after it reconnects." }
        for command in commandNotification.keys.filter({ commandStates[$0] == "sending" }) {
            recordActionResult(command, state: "uncertain", reason: "Connection lost while sending. The action may have been sent; check your phone before trying again.")
        }
        for command in smsCommandPhone.keys where smsCommandPhone[command] == id && smsCommandStates[command] == "sending" {
            smsCommandStates[command] = "uncertain"
            smsCommandDetails[command] = "Connection lost while sending. The SMS may have been accepted; check your phone before trying again."
        }
        for i in transfers.indices where transfers[i].phoneId == id && ["Sending", "Receiving"].contains(transfers[i].status) { transfers[i].status = "Interrupted — reconnect to resume" }
        failPendingRemoteDownloads(phoneId: id,reason: "Android disconnected before the download completed.")
        clipboardCount = pasteboard.changeCount; save(); refreshCallPopup()
    }
    private func resetClipboardCount() { clipboardCount = pasteboard.changeCount }
    private func tick() {
        let count = pasteboard.changeCount
        if count != clipboardCount {
            clipboardCount = count
            if !clipboardPaused, !pausedClipboardDevices.contains(macId), !isSensitiveClipboard() {
                let source = NSWorkspace.shared.frontmostApplication?.localizedName
                if let image = clipboardPNG() { shareImage(image.data, width: image.width, height: image.height, sourceApp: source) }
                else if let text = pasteboard.string(forType: .string), text.utf8.count <= 65536 { shareText(text, sourceApp: source) }
            }
        }
        if Int(Date().timeIntervalSince1970) % 60 == 0 {
            let pruned = SyncRules.prune(notifications)
            if pruned.count != notifications.count { notifications = pruned; save() }
        }
        expirePendingRemoteDownloads()
    }
    private func isSensitiveClipboard() -> Bool {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        return types.contains { $0.contains("concealed") || $0.contains("TransientType") || $0.contains("AutoGeneratedType") }
    }
    func shareText(_ text: String, sourceApp: String? = "Android Sync") {
        guard !clipboardPaused, !pausedClipboardDevices.contains(macId), text.utf8.count <= 65536 else { return }
        let app = sourceApp ?? "Source unavailable"
        let id = UUID().uuidString
        let clock = nextClipboardClock(origin: macId)
        let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        let hash = SyncRules.hex(Data(SHA256.hash(data: Data(text.utf8))))
        clipboardText = text; clipboardOrigin = localDeviceName; clipboardSourceApp = app; clipboardImage = nil
        recordClipboardText(text,id: id,deviceId: macId,deviceName: localDeviceName,origin: localDeviceName,sourceApp: app,logicalClock: clock,createdAt: Date(timeIntervalSince1970: Double(createdAt) / 1000),contentHash: hash)
        let message = WireMessage("clipboard.propose",id: id,["clipId": id,"text": text,"origin": localDeviceName,"sourceApp": app,"originDeviceId": macId,"createdAt": createdAt,"contentHash": hash],originDeviceId: macId,clock: clock,capability: "clipboard")
        for peer in controls.values { peer.send(message) }
    }
    private func clipboardPNG() -> (data: Data, width: Int, height: Int)? {
        let data: Data
        if let png = pasteboard.data(forType: .png) { data = png }
        else if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { data = png }
        else { return nil }
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024, let image = NSImage(data: data) else { return nil }
        return (data, Int(image.size.width), Int(image.size.height))
    }
    private func shareImage(_ data: Data, width: Int, height: Int, sourceApp: String?) {
        guard !clipboardPaused, !pausedClipboardDevices.contains(macId), !data.isEmpty, data.count <= 25 * 1024 * 1024 else { return }
        do {
            let id = UUID().uuidString
            let clock = nextClipboardClock(origin: macId)
            let createdAt = Int64(Date().timeIntervalSince1970 * 1000)
            let app = sourceApp ?? "Source unavailable"
            let hash = SyncRules.hex(Data(SHA256.hash(data: data)))
            try recordClipboardImage(data,id: id,deviceId: macId,deviceName: localDeviceName,origin: localDeviceName,sourceApp: app,width: width,height: height,logicalClock: clock,createdAt: Date(timeIntervalSince1970: Double(createdAt) / 1000),contentHash: hash)
            clipboardText = "Image · \(width) × \(height)"; clipboardOrigin = localDeviceName; clipboardSourceApp = app; clipboardImage = NSImage(data: data)
            guard !controls.isEmpty else { return }
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = stagingDirectory.appendingPathComponent("clipboard-\(id).source")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let value = ClipboardImageSource(url: url,size: Int64(data.count),sha256: try SyncRules.fileHash(url),mime: "image/png",origin: localDeviceName,sourceApp: sourceApp,width: width,height: height,originDeviceId: macId,logicalClock: clock,createdAt: createdAt)
            clipboardImages[id] = value
            while clipboardImages.count > 20, let old = clipboardImages.keys.first { try? FileManager.default.removeItem(at: clipboardImages.removeValue(forKey: old)!.url) }
            let body: [String: Any] = ["clipId": id,"size": value.size,"sha256": value.sha256,"mime": value.mime,"origin": value.origin,"sourceApp": value.sourceApp ?? "Source unavailable","width": width,"height": height,"originDeviceId": macId,"createdAt": createdAt,"contentHash": hash,"acceptedClock": clock]
            let message = WireMessage("clipboard.image.propose",id: id,body,originDeviceId: macId,clock: clock,capability: "clipboard")
            controls.values.forEach { $0.send(message) }
        } catch { self.error = "Could not prepare the clipboard image: \(error.localizedDescription)" }
    }
    func shareLink(_ text: String) {
        guard SyncRules.validWebURL(text) != nil else { error = "Enter an http or https link."; return }
        controls.values.forEach { $0.send(WireMessage("link.share", ["url": text])) }
    }
    var clipboardDevices: [ClipboardDevice] {
        var names: [String: String] = [:]
        for record in clipboardHistory where record.deviceId != macId { if names[record.deviceId] == nil { names[record.deviceId] = record.deviceName } }
        for phone in phones { names[phone.id] = phone.name }
        let remote = names.map { ClipboardDevice(id: $0.key, name: $0.value, connected: connected.contains($0.key), local: false) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [ClipboardDevice(id: macId, name: "This Mac", connected: true, local: true)] + remote
    }
    func clipboardRecords(deviceId: String?, query: String) -> [ClipboardRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return clipboardHistory.filter { record in
            (deviceId == nil || record.deviceId == deviceId) && (needle.isEmpty || [record.text, record.sourceApp, record.deviceName, record.origin].contains { $0.localizedCaseInsensitiveContains(needle) })
        }
    }
    func clipboardImage(for record: ClipboardRecord) -> NSImage? {
        guard let name = record.imageFileName else { return nil }
        if let cached = clipboardImageCache.object(forKey: name as NSString) { return cached }
        guard let history, let data = try? history.loadClipboardImage(name), let image = NSImage(data: data) else { return nil }
        clipboardImageCache.setObject(image, forKey: name as NSString); return image
    }
    func copyClipboardRecord(_ record: ClipboardRecord) {
        if record.isImage {
            guard let image = clipboardImage(for: record) else { error = "This clipboard image could not be opened."; return }
            pasteboard.clearContents(); pasteboard.writeObjects([image]); clipboardImage = image
        } else {
            pasteboard.clearContents(); pasteboard.setString(record.text, forType: .string); clipboardImage = nil
        }
        clipboardCount = pasteboard.changeCount; showClipboardRecord(record)
    }
    func removeClipboardRecord(_ record: ClipboardRecord) {
        removeClipboardRecord(id: record.id)
    }
    private func removeClipboardRecord(id: String) {
        for record in clipboardHistory where record.id == id {
            if let name = record.imageFileName { history?.removeClipboardImage(name); clipboardImageCache.removeObject(forKey: name as NSString) }
        }
        clipboardHistory.removeAll { $0.id == id }; refreshLatestClipboard(); saveNow()
    }
    func deleteClipboardEverywhere(_ record: ClipboardRecord) {
        clipboardTombstones.insert(record.id)
        while clipboardTombstones.count > 4096 { clipboardTombstones.remove(clipboardTombstones.first!) }
        removeClipboardRecord(id: record.id)
        let clock = nextClipboardClock(origin: macId)
        let message = WireMessage("clipboard.delete",["targetId": record.id],originDeviceId: macId,clock: clock,capability: "clipboard")
        controls.values.forEach { $0.send(message) }
    }
    func toggleClipboardPin(_ record: ClipboardRecord) {
        guard let index = clipboardHistory.firstIndex(where: { $0.id == record.id }) else { return }
        clipboardHistory[index].pinned = clipboardHistory[index].pinned != true
        enforceClipboardQuota(); saveNow()
    }
    func toggleClipboardDevice(_ deviceId: String) {
        if pausedClipboardDevices.contains(deviceId) { pausedClipboardDevices.remove(deviceId) }
        else { pausedClipboardDevices.insert(deviceId) }
        clipboardCount = pasteboard.changeCount; saveNow()
    }
    var clipboardStorageBytes: Int64 { clipboardHistory.reduce(0) { $0 + clipboardRecordSize($1) } }
    func setClipboardQuota(_ bytes: Int64) {
        clipboardQuotaBytes = min(max(bytes,64 * 1024 * 1024),4 * 1024 * 1024 * 1024)
        if persistsPreferences { UserDefaults.standard.set(clipboardQuotaBytes,forKey: "clipboard-quota") }
        enforceClipboardQuota(); saveNow()
    }
    func clearClipboardHistory(deviceId: String? = nil) {
        let removed = clipboardHistory.filter { deviceId == nil || $0.deviceId == deviceId }
        for record in removed { if let name = record.imageFileName { history?.removeClipboardImage(name); clipboardImageCache.removeObject(forKey: name as NSString) } }
        clipboardHistory.removeAll { deviceId == nil || $0.deviceId == deviceId }
        refreshLatestClipboard(); saveNow()
    }
    private func recordClipboardText(_ text: String, id: String, deviceId: String, deviceName: String, origin: String, sourceApp: String, logicalClock: Int64, createdAt: Date, contentHash: String?) {
        let hash = contentHash ?? SyncRules.hex(Data(SHA256.hash(data: Data(text.utf8))))
        let record = ClipboardRecord(id: id,deviceId: deviceId,deviceName: String(deviceName.prefix(200)),origin: String(origin.prefix(200)),sourceApp: String(sourceApp.prefix(200)),kind: SyncRules.validWebURL(text) == nil ? "text" : "link",text: text,imageFileName: nil,width: nil,height: nil,logicalClock: logicalClock,contentHash: hash,byteSize: Int64(text.utf8.count),pinned: false,createdAt: createdAt)
        storeClipboardRecord(record)
    }
    private func recordClipboardImage(_ data: Data, id: String = UUID().uuidString, deviceId: String, deviceName: String, origin: String, sourceApp: String, width: Int, height: Int, logicalClock: Int64 = 0, createdAt: Date = Date(), contentHash: String? = nil) throws {
        guard let history else { throw StoreError(detail: "Encrypted clipboard storage is unavailable.") }
        let name = try history.saveClipboardImage(data, id: id)
        let hash = contentHash ?? SyncRules.hex(Data(SHA256.hash(data: data)))
        let record = ClipboardRecord(id: id,deviceId: deviceId,deviceName: String(deviceName.prefix(200)),origin: String(origin.prefix(200)),sourceApp: String(sourceApp.prefix(200)),kind: "image",text: "Image · \(width) × \(height)",imageFileName: name,width: width,height: height,logicalClock: logicalClock,contentHash: hash,byteSize: Int64(data.count),pinned: false,createdAt: createdAt)
        if let image = NSImage(data: data) { clipboardImageCache.setObject(image, forKey: name as NSString) }
        storeClipboardRecord(record)
    }
    private func storeClipboardRecord(_ record: ClipboardRecord) {
        guard !clipboardTombstones.contains(record.id) else { return }
        let retainedPin = clipboardHistory.first(where: { $0.id == record.id })?.pinned
        var updated = record; if retainedPin == true { updated.pinned = true }
        clipboardHistory.removeAll { $0.id == record.id }
        clipboardHistory.insert(updated,at: 0)
        clipboardHistory.sort {
            let left = $0.logicalClock ?? 0, right = $1.logicalClock ?? 0
            return left == right ? $0.createdAt > $1.createdAt : left > right
        }
        enforceClipboardQuota(); saveNow()
    }
    private func clipboardRecordSize(_ record: ClipboardRecord) -> Int64 {
        record.byteSize ?? Int64(record.text.utf8.count)
    }
    private func enforceClipboardQuota() {
        let pinnedUsage = Dictionary(grouping: clipboardHistory.filter { $0.pinned == true },by: \.deviceId).mapValues { $0.reduce(0) { $0 + clipboardRecordSize($1) } }
        var usage = pinnedUsage
        var retained: [ClipboardRecord] = []
        var evicted: [ClipboardRecord] = []
        for record in clipboardHistory {
            if record.pinned == true { retained.append(record); continue }
            let used = usage[record.deviceId] ?? 0
            if used + clipboardRecordSize(record) <= clipboardQuotaBytes {
                retained.append(record); usage[record.deviceId] = used + clipboardRecordSize(record)
            } else { evicted.append(record) }
        }
        for record in evicted { if let name = record.imageFileName { history?.removeClipboardImage(name); clipboardImageCache.removeObject(forKey: name as NSString) } }
        clipboardHistory = retained
    }
    private func nextClipboardClock(origin: String) -> Int64 {
        let highest = clipboardHistory.compactMap(\.logicalClock).max() ?? 0
        let next = max(highest,lastLiveClipboardOrder.clock) + 1
        lastLiveClipboardOrder = (next,origin); return next
    }
    private func showClipboardRecord(_ record: ClipboardRecord) {
        clipboardText = record.text; clipboardOrigin = record.origin; clipboardSourceApp = record.sourceApp
        clipboardImage = record.isImage ? clipboardImage(for: record) : nil
    }
    private func refreshLatestClipboard() {
        if let latest = clipboardHistory.first { showClipboardRecord(latest) }
        else { clipboardText = ""; clipboardOrigin = "Nothing shared yet"; clipboardSourceApp = "Source unavailable"; clipboardImage = nil }
    }
    func toggleClipboard() { clipboardPaused.toggle(); clipboardCount = pasteboard.changeCount; save() }
    func dismissLocal(_ key: String) {
        if let i = notifications.firstIndex(where: { $0.id == key }) { notifications[i].localDismissed = true; save() }
        if alertsEnabled { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key]) }
    }
    func dismissBluetoothCallPopup() { callPopupController?.dismissBluetooth() }
    func sendAction(key: String, kind: String, text: String? = nil, actionId: String? = nil, expectedTimestamp: Int64? = nil) {
        guard commandStates[key] != "sending" else { return }
        let item = notifications.first { $0.id == key }
        if let reason = SyncRules.notificationActionFailure(item, kind: kind, text: text, actionId: actionId, expectedTimestamp: expectedTimestamp) {
            latestNotificationCommand.removeValue(forKey: key); commandStates[key] = "failed"; commandDetails[key] = reason; return
        }
        guard let item, let phoneId = item.deviceId, let remoteId = item.remoteId else {
            latestNotificationCommand.removeValue(forKey: key); commandStates[key] = "failed"; commandDetails[key] = "This older history item is not linked to a known phone. Reply to a current notification."; return
        }
        guard let peer = controls[phoneId] else { latestNotificationCommand.removeValue(forKey: key); commandStates[key] = "failed"; commandDetails[key] = "The phone that owns this notification is offline. Reconnect it before replying."; return }
        let id = UUID().uuidString
        var body: [String: Any] = ["key": remoteId, "kind": kind]
        body["expectedTimestamp"] = expectedTimestamp ?? item.timestamp
        if let text { body["text"] = text }; if let actionId { body["actionId"] = actionId }
        commandStates[id] = "sending"; commandStates[key] = "sending"; commandNotification[id] = key; commandPhone[id] = phoneId; latestNotificationCommand[key] = id
        commandDetails[key] = "Sending action to your phone…"
        peer.send(WireMessage("notification.action", id: id, body))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, self.commandStates[id] == "sending" else { return }
            self.recordActionResult(id, state: "uncertain", reason: "No confirmation received. The reply may have been sent; check your phone before trying again.")
        }
    }
    private func recordActionResult(_ id: String, state: String, reason: String?) {
        guard let key = commandNotification[id] else { return }
        let result = ["accepted", "failed", "uncertain"].contains(state) ? state : "uncertain"
        commandStates[id] = result
        commandPhone.removeValue(forKey: id)
        guard latestNotificationCommand[key] == id else { return }
        commandStates[key] = result
        commandDetails[key] = reason?.isEmpty == false ? String(reason!.prefix(1000)) : result == "failed" ? "Android could not perform the action. Refresh notifications and try a current notification." : result == "uncertain" ? "The action may have been sent. Check your phone before trying again." : "Android accepted the action. Message delivery is controlled by the source app."
    }
    func clearHistory() { notifications.removeAll(); notificationAppIcons.removeAll(); notificationIconCache.removeAllObjects(); clearedAt = Int64(Date().timeIntervalSince1970 * 1000); if alertsEnabled { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }; save() }
    func excludeApp(_ package: String) {
        if alertsEnabled { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifications.filter { $0.package == package }.map(\.id)) }
        excluded.insert(package); notifications.removeAll { $0.package == package }
        notificationAppIcons = notificationAppIcons.filter { $0.key != package && !$0.key.hasSuffix("::\(package)") }
        notificationIconCache.removeAllObjects(); save()
    }
    func allowApp(_ package: String) { excluded.remove(package); save() }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { self.error = error.localizedDescription }
    }
    func exportRedactedDiagnostics() {
        func transferBucket(_ status: String) -> String {
            if status == "Completed" { return "completed" }
            if status.hasPrefix("Failed") { return "failed" }
            if ["Cancelled", "Declined"].contains(status) { return "cancelled" }
            return "active"
        }
        func capabilityBucket(_ status: String) -> String {
            let value = status.lowercased().replacingOccurrences(of: " ", with: "_")
            return ["enabled", "available", "permission_required", "temporarily_unavailable", "unsupported"].contains(value) ? value : "unknown"
        }
        #if arch(arm64)
        let runtimeArchitecture = "arm64"
        #elseif arch(x86_64)
        let runtimeArchitecture = "x86_64"
        #else
        let runtimeArchitecture = "unknown"
        #endif
        let transferStates = Dictionary(grouping: transfers, by: { transferBucket($0.status) }).mapValues(\.count)
        let capabilityStates = Dictionary(grouping: phoneStatuses.values.flatMap { $0.capabilities.values }, by: capabilityBucket).mapValues(\.count)
        let report = RedactedDiagnosticsReport(
            generatedAt: Date(),
            app: .init(
                name: "Android Sync",
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            ),
            platform: .init(
                name: "macOS",
                version: ProcessInfo.processInfo.operatingSystemVersionString,
                runtimeArchitecture: runtimeArchitecture,
                buildArchitectures: ["arm64", "x86_64"]
            ),
            devices: .init(paired: phones.count, connected: connected.count),
            health: .init(
                nativeAlerts: alertsAuthorized ? "enabled" : "permission_required",
                clipboardPaused: clipboardPaused
            ),
            historyCounts: .init(
                notifications: notifications.count,
                clipboard: clipboardHistory.count,
                transfers: transfers.count,
                smsThreads: smsThreads.count,
                smsMessages: smsMessages.count,
                contacts: contacts.count
            ),
            transferStates: transferStates,
            phoneCapabilityStates: capabilityStates
        )
        let panel = NSSavePanel()
        panel.title = "Export redacted diagnostics"
        panel.nameFieldStringValue = "android-sync-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url, options: [.atomic])
        } catch { self.error = "Could not export diagnostics: \(error.localizedDescription)" }
    }
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self else { return }
            self.persistHistory()
        }
    }
    private func saveNow() { saveTask?.cancel(); persistHistory() }
    private func persistHistory() {
        let retainedIconKeys = Set(notifications.flatMap { [$0.package, notificationIconKey(deviceId: $0.deviceId, package: $0.package)] })
        let retainedIcons = notificationAppIcons.filter { retainedIconKeys.contains($0.key) }
        let state = HistoryState(notifications: notifications,notificationAppIcons: retainedIcons,transfers: transfers,excluded: excluded,pausedClipboard: clipboardPaused,clearedAt: clearedAt,clipboardHistory: clipboardHistory,clipboardTombstones: Array(clipboardTombstones),pausedClipboardDevices: pausedClipboardDevices,askEveryTimeFiles: askEveryTimeFiles,smsThreads: smsThreads,smsMessages: smsMessages,contacts: contacts,callHistory: callHistory)
        do {
            try history?.save(state)
            if history != nil { cleanupTerminalTransfers() }
        } catch { self.error = "Could not save local history: \(error.localizedDescription)" }
    }
    private func showNotification(_ item: PhoneNotification) {
        guard alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        let preview = NotificationPreview(sourceApp: item.app, title: item.title, body: item.text,
                                          privacyEnabled: UserDefaults.standard.bool(forKey: "streamModeEnabled"))
        content.title = preview.title
        content.subtitle = preview.subtitle
        content.body = preview.body
        if !preview.hidden, let attachment = notificationIconAttachment(for: item) { content.attachments = [attachment] }
        content.sound = .default
        content.threadIdentifier = "android-app-\(item.package)"
        content.categoryIdentifier = preview.hidden ? "" : (callNotificationCategory(item) ?? (item.reply ? "PHONE_REPLY" : "PHONE"))
        content.userInfo = ["key": item.id, "timestamp": item.timestamp, "privacyHidden": preview.hidden]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }
    var activeCallNotification: PhoneNotification? {
        notifications.filter { item in
            item.active && (item.call == true || !(item.callActions ?? []).isEmpty) && item.deviceId.map { connected.contains($0) } == true
        }
            .sorted {
                let left = (($0.callState == "incoming" ? 100 : 0) + ($0.callActions?.count ?? 0), $0.timestamp)
                let right = (($1.callState == "incoming" ? 100 : 0) + ($1.callActions?.count ?? 0), $1.timestamp)
                return left > right
            }.first
    }
    private func refreshCallPopup() { callPopupController?.refresh() }
    func dismissCallPopup(_ id: String, timestamp: Int64) { callPopupController?.dismiss(id: id, timestamp: timestamp) }
    func callDisplayNumber(for item: PhoneNotification) -> String? {
        if let number = item.callerNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty { return number }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedPhone(title).count >= 7 ? title : nil
    }
    func callDisplayName(for item: PhoneNotification) -> String {
        if let contact = matchingCallerContact(for: item), !contact.name.isEmpty { return contact.name }
        if let name = item.callerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, normalizedPhone(name).count < 7 { return name }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = ["call", "incoming call", "ongoing call", "call in progress"]
        if !title.isEmpty, !generic.contains(title.lowercased()), normalizedPhone(title).count < 7 { return title }
        return callDisplayNumber(for: item) ?? "Unknown caller"
    }
    func callCallerImage(for item: PhoneNotification) -> NSImage? {
        guard let encoded = item.callerImage, encoded.utf8.count <= 90_000, let data = Data(base64Encoded: encoded), data.count <= 64 * 1024 else { return nil }
        return NSImage(data: data)
    }
    private func matchingCallerContact(for item: PhoneNotification) -> ContactRecord? {
        guard let number = callDisplayNumber(for: item) else { return nil }
        let normalized = normalizedPhone(number)
        guard normalized.count >= 7 else { return nil }
        return contacts.first { contact in
            (contact.deviceId == nil || item.deviceId == nil || contact.deviceId == item.deviceId) && contact.phones.contains { candidate in
                let other = normalizedPhone(candidate)
                let matchLength = min(10,min(normalized.count,other.count))
                return matchLength >= 7 && normalized.suffix(matchLength) == other.suffix(matchLength)
            }
        }
    }
    private func normalizedPhone(_ value: String) -> String { String(value.filter(\.isNumber)) }
    private func callNotificationCategory(_ item: PhoneNotification) -> String? {
        var mask = 0
        for action in item.callActions ?? [] {
            switch action.kind { case "answer": mask |= 1; case "decline": mask |= 2; case "mute": mask |= 4; case "declineMessage": mask |= 8; default: break }
        }
        if (item.call == true || !(item.callActions ?? []).isEmpty), item.deviceId == bluetoothCalls.selectedPhoneId {
            if bluetoothCalls.canAnswer { mask |= 1 }
            if bluetoothCalls.canEnd { mask |= 2 }
        }
        return mask == 0 ? nil : "PHONE_CALL_\(mask)"
    }
    func notificationDeviceConnected(_ item: PhoneNotification) -> Bool {
        guard let deviceId = item.deviceId else { return false }
        return connected.contains(deviceId)
    }
    func notificationDeviceName(_ item: PhoneNotification) -> String? {
        guard let deviceId = item.deviceId else { return nil }
        return phones.first(where: { $0.id == deviceId })?.name ?? "Removed Android device"
    }
    func notificationAppIcon(for item: PhoneNotification) -> NSImage? {
        let key = notificationIconKey(deviceId: item.deviceId, package: item.package)
        if let cached = notificationIconCache.object(forKey: key as NSString) { return cached }
        guard let data = notificationAppIcons[key] ?? notificationAppIcons[item.package], let image = NSImage(data: data) else { return nil }
        notificationIconCache.setObject(image, forKey: key as NSString)
        return image
    }
    private func acceptNotificationAppIcon(_ encoded: String, package: String, deviceId: String) {
        guard package.count <= 255, encoded.utf8.count <= 90_000, let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 64 * 1024,
              let image = NSImage(data: data), image.isValid else { return }
        let key = notificationIconKey(deviceId: deviceId, package: package)
        guard notificationAppIcons[key] != data else { return }
        notificationAppIcons[key] = data
        notificationIconCache.setObject(image, forKey: key as NSString)
    }
    private func notificationIconAttachment(for item: PhoneNotification) -> UNNotificationAttachment? {
        let key = notificationIconKey(deviceId: item.deviceId, package: item.package)
        guard let data = notificationAppIcons[key] ?? notificationAppIcons[item.package] else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidSyncNotificationIcons", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: "android-app-icon", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
        } catch { return nil }
    }
    private func notificationIconKey(deviceId: String?, package: String) -> String {
        deviceId.map { "\($0)::\(package)" } ?? package
    }
    private func showSimpleAlert(_ title: String, text: String, sound: Bool = false, identifier: String = UUID().uuidString, section: String? = nil) {
        guard alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        let preview = NotificationPreview(sourceApp: "Android Sync", title: title, body: text,
                                          privacyEnabled: UserDefaults.standard.bool(forKey: "streamModeEnabled"))
        content.title = preview.title
        content.body = preview.body
        content.userInfo = ["privacyHidden": preview.hidden]
        if sound { content.sound = .default }
        if let section { content.userInfo["section"] = section }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor in self?.error = "Could not deliver a Mac alert: \(error.localizedDescription)" } }
        }
    }
    private func notifyTransferCompletion(_ id: String) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].status == "Completed", transfers[i].completionNotified != true else { return }
        transfers[i].completionNotified = true
        finishPendingRemoteDownload(id,error: nil)
        guard fileAlerts else { return }
        let transfer = transfers[i]
        let name = phones.first(where: { $0.id == transfer.phoneId })?.name ?? "your phone"
        let count = transfer.offer.files.count
        showSimpleAlert(transfer.incoming ? "Files received" : "Files sent", text: "\(count) \(count == 1 ? "file" : "files") \(transfer.incoming ? "from" : "to") \(name) · \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))", sound: fileSounds, identifier: "transfer-\(id)", section: "File Transfer")
    }
    private func notifyTransferFailure(_ id: String) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].status.hasPrefix("Failed"), transfers[i].failureNotified != true else { return }
        transfers[i].failureNotified = true
        finishPendingRemoteDownload(id,error: StoreError(detail: transfers[i].status))
        guard fileAlerts else { return }
        let transfer = transfers[i]
        let name = phones.first(where: { $0.id == transfer.phoneId })?.name ?? "your phone"
        showSimpleAlert("File transfer failed", text: "The batch \(transfer.incoming ? "from" : "to") \(name) could not finish. Open File Transfer to retry.", sound: fileSounds, identifier: "transfer-failed-\(id)", section: "File Transfer")
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A mode change can race an already queued foreground delivery.
        if UserDefaults.standard.bool(forKey: "streamModeEnabled"),
           notification.request.content.userInfo["privacyHidden"] as? Bool != true {
            center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if let section = response.notification.request.content.userInfo["section"] as? String { self.requestedSection = section }
            let key = response.notification.request.content.userInfo["key"] as? String
            if let key {
                let timestamp = (response.notification.request.content.userInfo["timestamp"] as? NSNumber)?.int64Value
                let callKinds = ["CALL_ANSWER": "answer", "CALL_DECLINE": "decline", "CALL_MUTE": "mute", "CALL_DECLINE_MESSAGE": "declineMessage"]
                if let item = self.notifications.first(where: { $0.id == key }), item.deviceId == self.bluetoothCalls.selectedPhoneId,
                   response.actionIdentifier == "CALL_ANSWER", self.bluetoothCalls.canAnswer {
                    self.bluetoothCalls.answerOnMac()
                }
                else if let item = self.notifications.first(where: { $0.id == key }), item.deviceId == self.bluetoothCalls.selectedPhoneId,
                        response.actionIdentifier == "CALL_DECLINE", self.bluetoothCalls.canEnd {
                    self.bluetoothCalls.endCall()
                }
                else if let kind = callKinds[response.actionIdentifier], let item = self.notifications.first(where: { $0.id == key }), let action = item.callActions?.first(where: { $0.kind == kind }) {
                    let text = (response as? UNTextInputNotificationResponse)?.userText
                    self.sendAction(key: key, kind: "call", text: text, actionId: action.id, expectedTimestamp: timestamp)
                }
                else if response.actionIdentifier == "REPLY", let reply = response as? UNTextInputNotificationResponse { self.sendAction(key: key, kind: "reply", text: reply.userText, expectedTimestamp: timestamp) }
                else if response.actionIdentifier == "DISMISS_PHONE" { self.sendAction(key: key, kind: "dismiss", expectedTimestamp: timestamp) }
                else if response.actionIdentifier == UNNotificationDismissActionIdentifier { self.dismissLocal(key) }
                else { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            } else { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            completionHandler()
        }
    }
}

extension AppModel {
    private var stagingDirectory: URL { history!.directory.appendingPathComponent("Transfers", isDirectory: true) }
    private func partialURL(_ offerId: String, _ fileId: String) -> URL { stagingDirectory.appendingPathComponent("\(offerId)-\(fileId).part") }
    private func cleanupTerminalTransfers() {
        for transfer in transfers where ["Completed", "Cancelled", "Declined"].contains(transfer.status) {
            for file in transfer.offer.files {
                try? FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(file.id + ".source"))
                try? FileManager.default.removeItem(at: partialURL(transfer.id, file.id))
            }
        }
    }
    private func offsets(for record: TransferRecord) -> [String: Int64] {
        var offsets: [String: Int64] = [:]
        for file in record.offer.files {
            if record.completed.contains(file.id) { offsets[file.id] = file.size }
            else { offsets[file.id] = ((try? FileManager.default.attributesOfItem(atPath: partialURL(record.id, file.id).path)[.size]) as? NSNumber)?.int64Value ?? 0 }
        }
        return offsets
    }
    private func handleRemoteDownloadResult(body: [String: Any], isGallery: Bool) {
        let failedMessage = body["reason"] as? String ?? "Could not prepare the selected files."
        guard let requestId = body["requestId"] as? String, let pending = pendingRemoteDownloadRequests.removeValue(forKey: requestId) else {
            if body["state"] as? String == "failed" { if isGallery { galleryMessage = failedMessage } else { remoteStorageMessage = failedMessage } }
            return
        }
        guard body["state"] as? String == "accepted", let transferId = body["transferId"] as? String, UUID(uuidString: transferId) != nil else {
            if pending.securityScoped { pending.folder.stopAccessingSecurityScopedResource() }
            pending.completion?(StoreError(detail: failedMessage))
            if isGallery { galleryMessage = failedMessage } else { remoteStorageMessage = failedMessage }
            return
        }
        var waiting = pending; waiting.waitingSince = Date()
        pendingRemoteDownloadTransfers[transferId] = waiting
        if isGallery {
            galleryTransferId = transferId
            galleryMessage = "Preparing the selected media for download…"
        }
        else {
            remoteStorageTransferId = transferId
            remoteStorageMessage = "Preparing the selected files and folders for download…"
        }
    }
    private func finishPendingRemoteDownload(_ transferId: String, error: Error?) {
        guard let pending = pendingRemoteDownloadTransfers.removeValue(forKey: transferId) else { return }
        if pending.securityScoped { pending.folder.stopAccessingSecurityScopedResource() }
        let message = error?.localizedDescription ?? "Downloaded \(pending.itemCount) \(pending.itemCount == 1 ? "item" : "items") successfully."
        if pending.isGallery { galleryMessage = message } else { remoteStorageMessage = message }
        pending.completion?(error)
    }
    private func failPendingRemoteDownloads(phoneId: String, reason: String) {
        let failure = StoreError(detail: reason)
        for requestId in pendingRemoteDownloadRequests.filter({ $0.value.phoneId == phoneId }).map(\.key) {
            guard let pending = pendingRemoteDownloadRequests.removeValue(forKey: requestId) else { continue }
            if pending.securityScoped { pending.folder.stopAccessingSecurityScopedResource() }
            if pending.isGallery { galleryMessage = reason } else { remoteStorageMessage = reason }
            pending.completion?(failure)
        }
        for transferId in pendingRemoteDownloadTransfers.filter({ $0.value.phoneId == phoneId }).map(\.key) {
            finishPendingRemoteDownload(transferId,error: failure)
        }
    }
    private func expirePendingRemoteDownloads() {
        let now = Date()
        let requestTimeout = pendingRemoteDownloadRequests.filter { now.timeIntervalSince($0.value.waitingSince) > 300 }.map(\.key)
        for requestId in requestTimeout {
            guard let pending = pendingRemoteDownloadRequests.removeValue(forKey: requestId) else { continue }
            if pending.securityScoped { pending.folder.stopAccessingSecurityScopedResource() }
            let failure = StoreError(detail: "Android did not prepare the download in time. Try again.")
            if pending.isGallery { galleryMessage = failure.localizedDescription } else { remoteStorageMessage = failure.localizedDescription }
            pending.completion?(failure)
        }
        let missingOffers = pendingRemoteDownloadTransfers.filter { transferId, pending in
            !transfers.contains(where: { $0.id == transferId }) && now.timeIntervalSince(pending.waitingSince) > 15
        }.map(\.key)
        for transferId in missingOffers { finishPendingRemoteDownload(transferId,error: StoreError(detail: "Android prepared the download but did not start its transfer. Try again.")) }
    }
    private func beginRemoteDownload(phoneId: String, type: String, key: String, values: [String], destinationFolder: URL?, completion: ((Error?) -> Void)?) {
        guard let peer = controls[phoneId], !values.isEmpty, values.count <= 100 else {
            let failure = StoreError(detail: "Choose between 1 and 100 items from a connected Android device.")
            completion?(failure); error = failure.localizedDescription; return
        }
        let folder = destinationFolder ?? receiveFolder
        let securityScoped = destinationFolder != nil && folder.standardizedFileURL != receiveFolder.standardizedFileURL && folder.startAccessingSecurityScopedResource()
        let requestId = UUID().uuidString
        let isGallery = type == "gallery.download"
        pendingRemoteDownloadRequests[requestId] = PendingRemoteDownload(phoneId: phoneId,folder: folder,completion: completion,securityScoped: securityScoped,isGallery: isGallery,itemCount: values.count,waitingSince: Date())
        if isGallery {
            galleryTransferId = nil
            galleryMessage = "Preparing \(values.count) \(values.count == 1 ? "item" : "items") on Android…"
        } else if type == "storage.download" {
            remoteStorageTransferId = nil
            remoteStorageMessage = "Preparing \(values.count) \(values.count == 1 ? "item" : "items") on Android…"
        }
        peer.send(WireMessage(type,["requestId": requestId,key: values],capability: "files"))
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { offerFiles(panel.urls) }
    }
    func browseStorage(phoneId: String, path: String = "") {
        guard let peer = controls[phoneId] else { remoteStorageMessage = "Reconnect this Android device to browse its files."; return }
        remoteStoragePhoneId = phoneId; remoteStorageLoading = true; remoteStorageMessage = nil; remoteStorageHasMore = false; remoteStorageNextOffset = 0
        peer.send(WireMessage("storage.list", ["path": path,"offset": 0,"limit": 100], capability: "files"))
    }
    func loadMoreStorage() {
        guard !remoteStorageLoading, remoteStorageHasMore, let phoneId = remoteStoragePhoneId, let peer = controls[phoneId] else { return }
        remoteStorageLoading = true
        peer.send(WireMessage("storage.list", ["path": remoteStoragePath,"offset": remoteStorageNextOffset,"limit": 100], capability: "files"))
    }
    func downloadRemoteFiles(_ paths: [String], destinationFolder: URL? = nil, completion: ((Error?) -> Void)? = nil) {
        guard let phoneId = remoteStoragePhoneId else { remoteStorageMessage = "Choose a connected Android device."; return }
        beginRemoteDownload(phoneId: phoneId,type: "storage.download",key: "paths",values: paths,destinationFolder: destinationFolder,completion: completion)
        remoteStorageMessage = "Preparing \(paths.count) \(paths.count == 1 ? "file" : "files") on Android…"
    }
    func downloadRemoteFile(_ path: String, phoneId: String, destinationFolder: URL, completion: @escaping (Error?) -> Void) {
        beginRemoteDownload(phoneId: phoneId,type: "storage.download",key: "paths",values: [path],destinationFolder: destinationFolder,completion: completion)
    }
    func downloadRemoteFiles(_ paths: [String], phoneId: String, destinationFolder: URL, completion: @escaping (Error?) -> Void) {
        beginRemoteDownload(phoneId: phoneId,type: "storage.download",key: "paths",values: paths,destinationFolder: destinationFolder,completion: completion)
    }
    func browseGallery(phoneId: String) {
        guard let peer = controls[phoneId] else { galleryMessage = "Reconnect this Android device to browse its photos."; return }
        galleryPhoneId = phoneId; galleryEntries = []; galleryNextCursor = 0; galleryHasMore = false; galleryLoading = true; galleryMessage = nil; galleryTransferId = nil
        peer.send(WireMessage("gallery.list",["cursor": 0,"limit": 20],capability: "files"))
    }
    func loadMoreGallery() {
        guard !galleryLoading, galleryHasMore, let phoneId = galleryPhoneId, let peer = controls[phoneId] else { return }
        galleryLoading = true
        peer.send(WireMessage("gallery.list",["cursor": galleryNextCursor,"limit": 20],capability: "files"))
    }
    func requestGalleryThumbnail(_ entry: MediaEntry) {
        guard let phoneId = galleryPhoneId, let peer = controls[phoneId] else { return }
        let key = galleryThumbnailKey(phoneId: phoneId,mediaId: entry.id)
        guard galleryThumbnails[key] == nil, requestedGalleryThumbnails.insert(key).inserted else { return }
        peer.send(WireMessage("gallery.thumbnail",["mediaId": entry.id],capability: "files"))
    }
    func galleryThumbnail(for entry: MediaEntry) -> NSImage? {
        guard let phoneId = galleryPhoneId, let data = galleryThumbnails[galleryThumbnailKey(phoneId: phoneId,mediaId: entry.id)] else { return nil }
        return NSImage(data: data)
    }
    private func galleryThumbnailKey(phoneId: String, mediaId: String) -> String { "\(phoneId)::\(mediaId)" }
    func downloadGallery(_ mediaIds: [String], destinationFolder: URL? = nil, completion: ((Error?) -> Void)? = nil) {
        guard let phoneId = galleryPhoneId else { galleryMessage = "Choose a connected Android device."; return }
        beginRemoteDownload(phoneId: phoneId,type: "gallery.download",key: "mediaIds",values: mediaIds,destinationFolder: destinationFolder,completion: completion)
        galleryMessage = "Preparing \(mediaIds.count) \(mediaIds.count == 1 ? "item" : "items") on Android…"
    }
    func downloadGalleryItem(_ mediaId: String, phoneId: String, destinationFolder: URL, completion: @escaping (Error?) -> Void) {
        beginRemoteDownload(phoneId: phoneId,type: "gallery.download",key: "mediaIds",values: [mediaId],destinationFolder: destinationFolder,completion: completion)
    }
    func downloadGallery(_ mediaIds: [String], phoneId: String, destinationFolder: URL, completion: @escaping (Error?) -> Void) {
        beginRemoteDownload(phoneId: phoneId,type: "gallery.download",key: "mediaIds",values: mediaIds,destinationFolder: destinationFolder,completion: completion)
    }
    func offerFiles(_ urls: [URL], phoneId requestedPhoneId: String? = nil, targetPath: String? = nil) {
        let phoneId = requestedPhoneId ?? controls.keys.sorted().first
        guard let phoneId, controls[phoneId] != nil, history != nil else { error = "Connect your phone before sending files."; return }
        guard !urls.isEmpty, urls.count <= 100 else { error = "Choose up to 100 files per batch."; return }
        preparingFiles = true
        let directory = stagingDirectory
        Task {
            do {
                let prepared: (FileOffer, [String: String]) = try await Task.detached {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    var files: [SharedFile] = []; var paths: [String: String] = [:]
                    var staged: [URL] = []; var succeeded = false
                    defer { if !succeeded { for url in staged { try? FileManager.default.removeItem(at: url) } } }
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard values.isRegularFile == true else { throw StoreError(detail: "Only regular files can be sent.") }
                        let id = UUID().uuidString; let copy = directory.appendingPathComponent(id + ".source")
                        staged.append(copy)
                        try FileManager.default.copyItem(at: url, to: copy)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                        let size = ((try FileManager.default.attributesOfItem(atPath: copy.path)[.size]) as! NSNumber).int64Value
                        let file = SharedFile(id: id, name: url.lastPathComponent, size: size, sha256: try SyncRules.fileHash(copy), mime: "application/octet-stream")
                        try file.validate(); files.append(file); paths[id] = copy.path
                    }
                    let offer = FileOffer(files: files,targetPath: targetPath); try offer.validate(); succeeded = true; return (offer, paths)
                }.value
                let record = TransferRecord(offer: prepared.0, phoneId: phoneId, incoming: false, status: "Awaiting phone acceptance", sourcePaths: prepared.1)
                transfers.insert(record, at: 0); save(); controls[phoneId]?.send(WireMessage("file.offer", WireMessage.object(prepared.0)))
            } catch { self.error = "Could not prepare files: \(error.localizedDescription)" }
            preparingFiles = false
        }
    }
    func acceptTransfer(_ id: String) {
        guard let i = transfers.firstIndex(where: { $0.id == id && $0.incoming }), let peer = controls[transfers[i].phoneId] else { error = "Reconnect the phone before accepting."; return }
        let folder = URL(fileURLWithPath: transfers[i].receiveFolderPath ?? receiveFolder.path, isDirectory: true)
        let remaining = transfers[i].total - transfers[i].completed.compactMap { completed in transfers[i].offer.files.first(where: { $0.id == completed })?.size }.reduce(0,+)
        let available = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard remaining <= max(0,available - 16 * 1024 * 1024) else {
            transfers[i].status = "Failed — not enough free space"; transfers[i].accepted = false
            peer.send(WireMessage("file.decline", ["transferId": id,"reason": "insufficient_storage"]))
            error = "The Mac receiving folder does not have enough free space for this batch."; notifyTransferFailure(id); save(); return
        }
        transfers[i].accepted = true; transfers[i].status = "Receiving"; transfers[i].startedAt = transfers[i].startedAt ?? Date()
        if transfers[i].receiveFolderPath == nil { transfers[i].receiveFolderPath = receiveFolder.path }
        save()
        peer.send(WireMessage("file.accept", ["transferId": id, "offsets": offsets(for: transfers[i])]))
    }
    func declineTransfer(_ id: String) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].status = "Declined"; transfers[i].accepted = false; save()
        finishPendingRemoteDownload(id,error: StoreError(detail: "Download declined."))
        controls[transfers[i].phoneId]?.send(WireMessage("file.decline", ["transferId": id])); closeTransferStreams(id)
    }
    func cancelTransfer(_ id: String) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].status = "Cancelled"; transfers[i].accepted = false; save()
        finishPendingRemoteDownload(id,error: StoreError(detail: "Download cancelled."))
        controls[transfers[i].phoneId]?.send(WireMessage("file.cancel", ["transferId": id])); closeTransferStreams(id)
    }
    func resumeTransfer(_ id: String) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), let peer = controls[transfers[i].phoneId] else { error = "Reconnect the phone to resume."; return }
        transfers[i].failureNotified = false
        if transfers[i].incoming { acceptTransfer(id) }
        else { transfers[i].accepted = false; transfers[i].status = "Awaiting phone acceptance"; peer.send(WireMessage("file.offer", WireMessage.object(transfers[i].offer))); save() }
    }
    private func closeTransferStreams(_ id: String) {
        for peer in Array(server?.peers.values ?? Dictionary<String, PeerConnection>().values) where peer.transferId == id { peer.close() }
    }
    private func updateProgress(_ index: Int, fileId: String, offset: Int64) {
        let completed = transfers[index].offer.files.filter { transfers[index].completed.contains($0.id) && $0.id != fileId }.reduce(Int64(0)) { $0 + $1.size }
        transfers[index].bytes = completed + offset
        if let started = transfers[index].startedAt {
            let elapsed = max(0.25,Date().timeIntervalSince(started))
            transfers[index].speedBytesPerSecond = Int64(Double(transfers[index].bytes) / elapsed)
        }
    }
    private func handleFile(_ peer: PeerConnection, _ message: WireMessage) {
        let b = message.body
        do {
            if message.type.hasPrefix("clipboard.") || peer.clipboardId != nil {
                try handleClipboardFile(peer, message)
                return
            }
            if ["file.put", "file.get"].contains(message.type) {
                guard peer.transferId == nil, let id = b["transferId"] as? String, let fileId = b["fileId"] as? String,
                      let i = transfers.firstIndex(where: { $0.id == id && $0.phoneId == peer.phoneId && $0.accepted }),
                      let file = transfers[i].offer.files.first(where: { $0.id == fileId }) else { peer.close(); return }
                guard transfers[i].incoming == (message.type == "file.put") else { peer.close(); return }
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                peer.transferId = id; peer.fileId = fileId
                if message.type == "file.put" {
                    if transfers[i].completed.contains(fileId) { peer.sendAndClose(WireMessage("file.saved", ["fileId": fileId])); return }
                    let url = partialURL(id, fileId)
                    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                    let handle = try FileHandle(forWritingTo: url); let offset = try handle.seekToEnd()
                    guard offset <= UInt64(file.size) else { try handle.close(); try FileManager.default.removeItem(at: url); throw ProtocolError.invalidFile }
                    peer.fileHandle = handle; peer.fileOffset = Int64(offset); transfers[i].status = "Receiving"
                } else {
                    guard let path = transfers[i].sourcePaths[fileId], let offset = b["offset"] as? Int64, offset >= 0, offset <= file.size else { throw ProtocolError.invalidFile }
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); try handle.seek(toOffset: UInt64(offset))
                    peer.fileHandle = handle; peer.fileOffset = offset; transfers[i].status = "Sending"
                }
                peer.send(WireMessage("file.ready", ["offset": peer.fileOffset, "fileId": fileId])); save(); return
            }
            guard let id = peer.transferId, let fileId = peer.fileId, let i = transfers.firstIndex(where: { $0.id == id && $0.accepted && $0.phoneId == peer.phoneId }),
                  let file = transfers[i].offer.files.first(where: { $0.id == fileId }) else { peer.close(); return }
            switch message.type {
            case "file.chunk":
                guard transfers[i].incoming, let handle = peer.fileHandle, let offset = b["offset"] as? Int64, offset == peer.fileOffset,
                      let base64 = b["data"] as? String, let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= 65536, offset + Int64(data.count) <= file.size else { throw ProtocolError.invalidFile }
                try handle.write(contentsOf: data); peer.fileOffset += Int64(data.count); updateProgress(i, fileId: fileId, offset: peer.fileOffset)
                peer.send(WireMessage("file.progress", ["offset": peer.fileOffset]))
            case "file.end":
                guard transfers[i].incoming, peer.fileOffset == file.size else { throw ProtocolError.invalidFile }
                try peer.fileHandle?.synchronize(); try peer.fileHandle?.close(); peer.fileHandle = nil
                let partial = partialURL(id, fileId)
                transfers[i].status = "Verifying"
                Task {
                    do {
                        let hash = try await Task.detached { try SyncRules.fileHash(partial) }.value
                        guard let index = self.transfers.firstIndex(where: { $0.id == id && $0.accepted }) else { peer.close(); return }
                        guard hash == file.sha256 else { try? FileManager.default.removeItem(at: partial); throw StoreError(detail: "File integrity check failed. Resume to retry.") }
                        let downloads = URL(fileURLWithPath: self.transfers[index].receiveFolderPath ?? self.receiveFolder.path, isDirectory: true)
                        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                        let destination = try self.destination(for: file,in: downloads)
                        try FileManager.default.moveItem(at: partial, to: destination)
                        self.transfers[index].completed.append(fileId); self.transfers[index].savedPaths[fileId] = destination.path
                        self.updateProgress(index, fileId: fileId, offset: file.size)
                        if self.transfers[index].completed.count == self.transfers[index].offer.files.count {
                            self.transfers[index].status = "Completed"; self.transfers[index].speedBytesPerSecond = 0; self.controls[self.transfers[index].phoneId]?.send(WireMessage("file.complete", ["transferId": id]))
                            self.notifyTransferCompletion(id)
                        } else { self.transfers[index].status = "Receiving" }
                        self.save(); peer.sendAndClose(WireMessage("file.saved", ["fileId": fileId]))
                    } catch {
                        if let index = self.transfers.firstIndex(where: { $0.id == id }) { self.transfers[index].status = "Failed — \(error.localizedDescription)"; self.notifyTransferFailure(id); self.save() }
                        peer.close()
                    }
                }
            case "file.next":
                guard !transfers[i].incoming, let handle = peer.fileHandle, b["offset"] as? Int64 == peer.fileOffset else { throw ProtocolError.invalidFile }
                if let data = try handle.read(upToCount: 65536), !data.isEmpty {
                    let offset = peer.fileOffset; peer.fileOffset += Int64(data.count); updateProgress(i, fileId: fileId, offset: peer.fileOffset)
                    peer.send(WireMessage("file.chunk", ["offset": offset, "data": data.base64EncodedString()]))
                } else { peer.send(WireMessage("file.end", ["fileId": fileId])) }
            case "file.saved":
                guard !transfers[i].incoming, peer.fileOffset == file.size else { throw ProtocolError.invalidFile }
                if !transfers[i].completed.contains(fileId) { transfers[i].completed.append(fileId) }
                if transfers[i].completed.count == transfers[i].offer.files.count { transfers[i].status = "Completed"; transfers[i].speedBytesPerSecond = 0 }
                notifyTransferCompletion(id)
                updateProgress(i, fileId: fileId, offset: file.size); save(); peer.close()
            default: throw ProtocolError.invalidMessage
            }
        } catch {
            if let id = peer.transferId, let i = transfers.firstIndex(where: { $0.id == id }) {
                transfers[i].status = "Interrupted — resume to retry"
                finishPendingRemoteDownload(id,error: StoreError(detail: "Download interrupted."))
                save()
            }
            peer.close()
        }
    }
    private func uniqueDestination(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let extensionName = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var index = 2
        repeat {
            let next = extensionName.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(extensionName)"
            candidate = folder.appendingPathComponent(next); index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
    private func destination(for file: SharedFile,in folder: URL) throws -> URL {
        guard let relativePath = file.relativePath else { return uniqueDestination(in: folder,name: file.name) }
        try file.validate()
        let components = relativePath.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw ProtocolError.invalidFile }
        let parent = components.dropLast().reduce(folder) { $0.appendingPathComponent($1,isDirectory: true) }
        let root = folder.standardizedFileURL.path
        let standardizedParent = parent.standardizedFileURL.path
        guard standardizedParent == root || standardizedParent.hasPrefix(root + "/") else { throw ProtocolError.invalidFile }
        try FileManager.default.createDirectory(at: parent,withIntermediateDirectories: true)
        return uniqueDestination(in: parent,name: leaf)
    }
    private func clipboardPartialURL(_ phoneId: String, _ clipId: String) -> URL {
        stagingDirectory.appendingPathComponent("\(phoneId)-clipboard-\(clipId).part")
    }
    private func handleClipboardFile(_ peer: PeerConnection, _ message: WireMessage) throws {
        let b = message.body
        if message.type == "clipboard.put" {
            guard peer.clipboardId == nil, let phoneId = peer.phoneId, let id = b["clipId"] as? String, UUID(uuidString: id) != nil,
                  let size = (b["size"] as? NSNumber)?.int64Value, size > 0, size <= 25 * 1024 * 1024,
                  let hash = b["sha256"] as? String, hash.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                  let mime = b["mime"] as? String, mime.hasPrefix("image/"), let origin = b["origin"] as? String, origin.count <= 200,
                  let revision = (b["revision"] as? NSNumber)?.int64Value, revision > 0,
                  let session = b["session"] as? String, !session.isEmpty, session.count <= 128 else { throw ProtocolError.invalidMessage }
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = clipboardPartialURL(phoneId, id)
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            peer.fileHandle = try FileHandle(forWritingTo: url)
            peer.clipboardId = id; peer.clipboardSize = size; peer.clipboardHash = hash; peer.clipboardMime = mime
            peer.clipboardOrigin = origin; peer.clipboardSourceApp = b["sourceApp"] as? String
            peer.clipboardSourcePackage = b["sourcePackage"] as? String
            peer.clipboardOriginDeviceId = b["originDeviceId"] as? String ?? phoneId
            peer.clipboardClock = (b["acceptedClock"] as? NSNumber)?.int64Value ?? revision
            peer.clipboardCreatedAt = min((b["createdAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000),Int64(Date().timeIntervalSince1970 * 1000) + 60_000)
            peer.clipboardRevision = revision; peer.clipboardSession = session; peer.fileOffset = 0
            peer.send(WireMessage("clipboard.ready", ["offset": Int64(0), "clipId": id]))
            return
        }
        if message.type == "clipboard.get" {
            guard peer.clipboardId == nil, let id = b["clipId"] as? String, let source = clipboardImages[id],
                  let offset = (b["offset"] as? NSNumber)?.int64Value, offset == 0 else { throw ProtocolError.invalidMessage }
            let handle = try FileHandle(forReadingFrom: source.url)
            peer.fileHandle = handle; peer.fileOffset = 0; peer.clipboardId = id; peer.clipboardSize = source.size
            peer.clipboardHash = source.sha256; peer.clipboardMime = source.mime; peer.clipboardOrigin = source.origin
            peer.clipboardSourceApp = source.sourceApp; peer.clipboardOriginDeviceId = source.originDeviceId
            peer.clipboardClock = source.logicalClock; peer.clipboardCreatedAt = source.createdAt; peer.clipboardRevision = -1
            peer.send(WireMessage("clipboard.ready", ["offset": Int64(0), "clipId": id]))
            return
        }
        guard let id = peer.clipboardId else { throw ProtocolError.invalidMessage }
        switch message.type {
        case "clipboard.chunk":
            guard peer.clipboardRevision > 0, let handle = peer.fileHandle,
                  let offset = (b["offset"] as? NSNumber)?.int64Value, offset == peer.fileOffset,
                  let encoded = b["data"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty,
                  data.count <= 65536, offset + Int64(data.count) <= peer.clipboardSize else { throw ProtocolError.invalidFile }
            try handle.write(contentsOf: data); peer.fileOffset += Int64(data.count)
            peer.send(WireMessage("clipboard.progress", ["offset": peer.fileOffset]))
        case "clipboard.end":
            guard peer.clipboardRevision > 0, peer.fileOffset == peer.clipboardSize, b["clipId"] as? String == id,
                  let phoneId = peer.phoneId else { throw ProtocolError.invalidFile }
            try peer.fileHandle?.synchronize(); try peer.fileHandle?.close(); peer.fileHandle = nil
            let url = clipboardPartialURL(phoneId, id)
            let data = try Data(contentsOf: url)
            guard try SyncRules.fileHash(url) == peer.clipboardHash, let image = NSImage(data: data) else {
                try? FileManager.default.removeItem(at: url); throw ProtocolError.invalidFile
            }
            let previousRevision = clipboardRevisions[phoneId]
            let freshRevision = previousRevision?.session != peer.clipboardSession || peer.clipboardRevision > (previousRevision?.revision ?? 0)
            clipboardRevisions[phoneId] = (peer.clipboardSession,peer.clipboardRevision)
            if freshRevision, !clipboardTombstones.contains(id), !pausedClipboardDevices.contains(peer.clipboardOriginDeviceId.isEmpty ? phoneId : peer.clipboardOriginDeviceId) {
                let originId = peer.clipboardOriginDeviceId.isEmpty ? phoneId : peer.clipboardOriginDeviceId
                let deviceName = originId == phoneId ? phones.first(where: { $0.id == phoneId })?.name ?? peer.clipboardOrigin : peer.clipboardOrigin
                try recordClipboardImage(data,id: id,deviceId: originId,deviceName: deviceName,origin: peer.clipboardOrigin,sourceApp: peer.clipboardSourceApp ?? "Source unavailable",width: Int(image.size.width),height: Int(image.size.height),logicalClock: peer.clipboardClock,createdAt: Date(timeIntervalSince1970: Double(peer.clipboardCreatedAt) / 1000),contentHash: peer.clipboardHash)
                let newer = peer.clipboardClock > lastLiveClipboardOrder.clock || (peer.clipboardClock == lastLiveClipboardOrder.clock && originId > lastLiveClipboardOrder.origin)
                if originId != macId, newer {
                    lastLiveClipboardOrder = (peer.clipboardClock,originId)
                    pasteboard.clearContents(); pasteboard.writeObjects([image]); clipboardCount = pasteboard.changeCount
                    clipboardImage = image; clipboardText = "Image · \(Int(image.size.width)) × \(Int(image.size.height))"
                    clipboardOrigin = peer.clipboardOrigin; clipboardSourceApp = peer.clipboardSourceApp ?? "Source unavailable"
                }
                let relayURL = stagingDirectory.appendingPathComponent("clipboard-\(id).source")
                try data.write(to: relayURL,options: .atomic)
                let source = ClipboardImageSource(url: relayURL,size: peer.clipboardSize,sha256: peer.clipboardHash,mime: peer.clipboardMime,origin: peer.clipboardOrigin,sourceApp: peer.clipboardSourceApp,width: Int(image.size.width),height: Int(image.size.height),originDeviceId: originId,logicalClock: peer.clipboardClock,createdAt: peer.clipboardCreatedAt)
                clipboardImages[id] = source
                let body: [String: Any] = ["clipId": id,"size": source.size,"sha256": source.sha256,"mime": source.mime,"origin": source.origin,"sourceApp": source.sourceApp ?? "Source unavailable","width": source.width,"height": source.height,"originDeviceId": originId,"createdAt": source.createdAt,"contentHash": source.sha256,"acceptedClock": source.logicalClock]
                let proposal = WireMessage("clipboard.image.propose",id: id,body,originDeviceId: originId,clock: source.logicalClock,capability: "clipboard")
                for (otherId, control) in controls where otherId != phoneId { control.send(proposal) }
            }
            try? FileManager.default.removeItem(at: url)
            peer.sendAndClose(WireMessage("clipboard.saved", ["clipId": id]))
        case "clipboard.next":
            guard peer.clipboardRevision == -1, let handle = peer.fileHandle,
                  (b["offset"] as? NSNumber)?.int64Value == peer.fileOffset else { throw ProtocolError.invalidFile }
            if let data = try handle.read(upToCount: 65536), !data.isEmpty {
                let offset = peer.fileOffset; peer.fileOffset += Int64(data.count)
                peer.send(WireMessage("clipboard.chunk", ["offset": offset, "data": data.base64EncodedString()]))
            } else { peer.send(WireMessage("clipboard.end", ["clipId": id])) }
        case "clipboard.saved":
            guard peer.clipboardRevision == -1, b["clipId"] as? String == id else { throw ProtocolError.invalidMessage }
            if let source = clipboardImages.removeValue(forKey: id) { try? FileManager.default.removeItem(at: source.url) }
            peer.close()
        default: throw ProtocolError.invalidMessage
        }
    }
}
