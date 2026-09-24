import Foundation
import Network
import Security
import AppKit

final class PeerConnection {
    let id = UUID().uuidString
    let connection: NWConnection
    let nonce: String
    var phoneId: String?
    var stream = ""
    var protocolVersion = 1
    var localDeviceId = ""
    var nextClock: (() -> Int64)?
    var authenticated = false
    var transferId: String?
    var fileId: String?
    var fileHandle: FileHandle?
    var fileOffset: Int64 = 0
    var clipboardId: String?
    var clipboardSize: Int64 = 0
    var clipboardHash = ""
    var clipboardMime = "image/png"
    var clipboardOrigin = "Phone"
    var clipboardSourceApp: String?
    var clipboardSourcePackage: String?
    var clipboardOriginDeviceId = ""
    var clipboardClock: Int64 = 0
    var clipboardCreatedAt: Int64 = 0
    var clipboardRevision: Int64 = 0
    var clipboardSession = ""
    private var framer = LineFramer()
    private var closed = false
    let queue: DispatchQueue
    var onMessage: ((PeerConnection, WireMessage) -> Void)?
    var onClose: ((PeerConnection) -> Void)?
    init(_ connection: NWConnection, queue: DispatchQueue) throws {
        self.connection = connection; self.queue = queue; nonce = try Vault.random(32).base64EncodedString()
    }
    func start(macId: String) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(WireMessage("auth.challenge", ["macId": macId, "nonce": self.nonce, "versions": [2, 1], "lanes": ["control", "bulk", "realtime"]], version: 1)); self.receive()
                self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in if self?.authenticated == false { self?.close() } }
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ message: WireMessage, completion: ((Bool) -> Void)? = nil) {
        let selected = authenticated ? protocolVersion : message.version
        let outgoing: WireMessage
        if authenticated, selected >= 2, message.originDeviceId == nil {
            outgoing = WireMessage(message.type, id: message.id, message.body, version: message.version, originDeviceId: localDeviceId, clock: nextClock?(), sentAt: message.sentAt, capability: message.capability, replyTo: message.replyTo)
        } else { outgoing = message }
        guard let data = try? outgoing.encoded(protocolVersion: selected), !closed else { completion?(false); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            completion?(error == nil); if error != nil { self?.close() }
        })
    }
    func sendAndClose(_ message: WireMessage) {
        send(message) { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.2) { self.close() }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                do { for frame in try self.framer.append(data) { self.onMessage?(self, try WireMessage(data: frame)) } }
                catch { self.close(); return }
            }
            if done || error != nil { self.close() } else { self.receive() }
        }
    }
    func close() { connection.cancel(); finish() }
    private func finish() { guard !closed else { return }; closed = true; try? fileHandle?.close(); fileHandle = nil; onClose?(self) }
}
final class LocalServer {
    let identity: MacIdentity
    let queue = DispatchQueue.main
    var listener: NWListener?
    var peers: [String: PeerConnection] = [:]
    var onMessage: ((PeerConnection, WireMessage) -> Void)?
    var onClose: ((PeerConnection) -> Void)?
    var onStatus: ((String, UInt16) -> Void)?
    private var clock = LogicalClock()
    private let clockLock = NSLock()
    init(identity: MacIdentity) { self.identity = identity }
    func start() throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: identity.id, type: "_androidsync._tcp")
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.onStatus?("Ready", listener?.port?.rawValue ?? 0)
            case .failed(let error): self?.onStatus?("Connection unavailable: \(error.localizedDescription)", 0)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.peers.count < 24, let peer = try? PeerConnection(connection, queue: self.queue) else { connection.cancel(); return }
            self.peers[peer.id] = peer; peer.localDeviceId = self.identity.id; peer.nextClock = { [weak self] in self?.tickClock() ?? 0 }
            peer.onMessage = { [weak self] p, m in self?.observeClock(m.clock); self?.onMessage?(p, m) }
            peer.onClose = { [weak self] p in self?.peers.removeValue(forKey: p.id); self?.onClose?(p) }
            peer.start(macId: self.identity.id)
        }
        self.listener = listener; listener.start(queue: queue)
    }
    private func tickClock() -> Int64 { clockLock.lock(); defer { clockLock.unlock() }; return clock.tick() }
    private func observeClock(_ remote: Int64?) { guard let remote else { return }; clockLock.lock(); _ = clock.observe(remote); clockLock.unlock() }
    static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }; defer { freeifaddrs(head) }
        var result: [String] = []; var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: item.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { result.append(String(cString: host)) }
        }
        return result
    }
}
