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
    let plain: Bool
    var transferId: String?
    var fileId: String?
    var fileHandle: FileHandle?
    var fileOffset: Int64 = 0
    var fileBinary = false
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
    private let fileQueue = DispatchQueue(label: "dev.androidsync.bulk-file", qos: .utility)
    private var rawRemaining: Int64 = 0
    private var lastRawProgress = Date.distantPast
    var onRawProgress: ((PeerConnection) -> Void)?
    var onRawComplete: ((PeerConnection) -> Void)?
    let queue: DispatchQueue
    var onMessage: ((PeerConnection, WireMessage) -> Void)?
    var onClose: ((PeerConnection) -> Void)?
    init(_ connection: NWConnection, queue: DispatchQueue, plain: Bool = false) throws {
        self.connection = connection; self.queue = queue; self.plain = plain
        nonce = try Vault.random(32).base64EncodedString()
    }
    func start(macId: String) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !self.plain {
                    self.send(WireMessage("auth.challenge", ["macId": macId, "nonce": self.nonce, "versions": [2, 1], "lanes": ["control", "bulk", "realtime"]], version: 1))
                }
                self.receive()
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
    /// Raw file bytes share this connection only after a JSON file.put header
    /// has been authenticated. Reads are serialized with disk writes, so the
    /// transport provides backpressure without keeping the full file in memory.
    func receiveRaw(_ count: Int64) {
        rawRemaining = count
        if count == 0 { onRawComplete?(self) }
    }
    func sendRawFile(_ handle: FileHandle, remaining: Int64, progress: @escaping (Int) -> Void, completion: @escaping (Bool) -> Void) {
        guard !closed else { completion(false); return }
        guard remaining > 0 else { completion(true); return }
        fileQueue.async { [weak self] in
            guard let self, !self.closed else { self?.queue.async { completion(false) }; return }
            do {
                guard let bytes = try handle.read(upToCount: Int(min(256 * 1024, remaining))), !bytes.isEmpty else {
                    self.queue.async { completion(false) }; return
                }
                self.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil, !self.closed else { completion(false); return }
                    progress(bytes.count)
                    self.sendRawFile(handle, remaining: remaining - Int64(bytes.count), progress: progress, completion: completion)
                })
            } catch { self.queue.async { completion(false) } }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: rawRemaining > 0 ? 256 * 1024 : 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                if self.rawRemaining > 0 {
                    let count = Int(min(Int64(data.count), self.rawRemaining))
                    let bytes = Data(data.prefix(count))
                    self.fileQueue.async { [weak self] in
                        guard let self, let handle = self.fileHandle else { self?.queue.async { self?.close() }; return }
                        do {
                            try handle.write(contentsOf: bytes)
                            let checkpoint: Int64 = 8 * 1024 * 1024
                            let previous = self.fileOffset
                            if (previous + Int64(count)) / checkpoint > previous / checkpoint {
                                try handle.synchronize()
                            }
                            self.queue.async {
                                self.fileOffset += Int64(count); self.rawRemaining -= Int64(count)
                                if Date().timeIntervalSince(self.lastRawProgress) >= 0.25 || self.rawRemaining == 0 {
                                    self.lastRawProgress = Date(); self.onRawProgress?(self)
                                }
                                if self.rawRemaining == 0 { self.onRawComplete?(self) }
                                if data.count > count {
                                    // The sender must wait for file.saved before sending another header.
                                    self.close()
                                } else if done || error != nil { self.close() }
                                else if self.rawRemaining > 0 { self.receive() }
                            }
                        } catch { self.queue.async { self.close() } }
                    }
                    return
                }
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
    var plainListener: NWListener?
    private(set) var plainPort: UInt16 = 0
    var peers: [String: PeerConnection] = [:]
    var onMessage: ((PeerConnection, WireMessage) -> Void)?
    var onClose: ((PeerConnection) -> Void)?
    var onStatus: ((String, UInt16) -> Void)?
    private var clock = LogicalClock()
    private let clockLock = NSLock()
    init(identity: MacIdentity) { self.identity = identity }
    func start() throws {
        guard let plain = try? NWListener(using: .tcp, on: .any) else {
            try startSecureListener()
            return
        }
        plain.stateUpdateHandler = { [weak self, weak plain] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.plainPort = plain?.port?.rawValue ?? 0
                do { try self.startSecureListener() }
                catch { self.onStatus?("Connection unavailable: \(error.localizedDescription)", 0) }
            case .failed:
                self.plainPort = 0
                do { try self.startSecureListener() }
                catch { self.onStatus?("Connection unavailable: \(error.localizedDescription)", 0) }
            default: break
            }
        }
        plain.newConnectionHandler = { [weak self] connection in
            guard let self, self.peers.count < 24, let peer = try? PeerConnection(connection, queue: self.queue, plain: true) else { connection.cancel(); return }
            self.peers[peer.id] = peer
            peer.onMessage = { [weak self] p, m in self?.onMessage?(p, m) }
            peer.onClose = { [weak self] p in self?.peers.removeValue(forKey: p.id); self?.onClose?(p) }
            peer.start(macId: self.identity.id)
        }
        plainListener = plain; plain.start(queue: queue)
    }
    private func startSecureListener() throws {
        guard listener == nil else { return }
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
    func closePlainStreams() {
        for peer in Array(peers.values) where peer.plain { peer.close() }
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
