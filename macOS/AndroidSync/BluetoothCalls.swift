import AppKit
import Foundation
import IOBluetooth

struct PairedCallDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let advertisesHandsFree: Bool
}

/// One Mac may hold one hands-free connection at a time. Wi-Fi device pairing
/// remains separate; the user explicitly maps a Bluetooth phone to it.
final class BluetoothCalls: NSObject, ObservableObject, IOBluetoothHandsFreeDeviceDelegate {
    @Published private(set) var pairedDevices: [PairedCallDevice] = []
    @Published var selectedAddress: String? {
        didSet {
            if selectedAddress != oldValue && isConnected { disconnect() }
            UserDefaults.standard.set(selectedAddress, forKey: "callBluetoothAddress")
        }
    }
    @Published var selectedPhoneId: String? {
        didSet {
            if selectedPhoneId != oldValue && isConnected { disconnect() }
            UserDefaults.standard.set(selectedPhoneId, forKey: "callPhoneId")
        }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var isCallActive = false
    @Published private(set) var callSetupMode = 0
    @Published private(set) var incomingNumber: String?
    @Published private(set) var status = "Pair your Android phone in macOS Bluetooth settings, then connect here."

    private var handsFree: IOBluetoothHandsFreeDevice?
    private var queryingDevice: IOBluetoothDevice?
    private var queryTimeout: Timer?
    private var connectionTimeout: Timer?
    private var callCommandTimeout: Timer?
    private var pendingCallCommand: String?

    override init() {
        selectedAddress = UserDefaults.standard.string(forKey: "callBluetoothAddress")
        selectedPhoneId = UserDefaults.standard.string(forKey: "callPhoneId")
        super.init()
    }

    var canAnswer: Bool { isConnected && callSetupMode == 1 }
    var canEnd: Bool { isConnected && (callSetupMode != 0 || isCallActive) }
    var selectedDeviceName: String { pairedDevices.first(where: { $0.id == selectedAddress })?.name ?? "Bluetooth phone" }

    func refreshPairedDevices() {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var seenAddresses = Set<String>()
        pairedDevices = devices.compactMap { device in
            guard let address = device.addressString else { return nil }
            guard seenAddresses.insert(address.lowercased()).inserted else { return nil }
            return PairedCallDevice(id: address, name: device.name ?? address,
                                    advertisesHandsFree: device.handsFreeAudioGatewayServiceRecord() != nil)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if pairedDevices.isEmpty {
            status = "No Bluetooth devices are paired with this Mac. Pair your phone in macOS settings first."
        } else if let selectedAddress, !pairedDevices.contains(where: { $0.id == selectedAddress }) {
            status = "The selected phone is no longer paired. Choose another Bluetooth device."
            disconnect()
        }
    }

    func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Bluetooth") else { return }
        NSWorkspace.shared.open(url)
    }

    func restoreConnection() {
        guard selectedAddress != nil, selectedPhoneId != nil else { return }
        refreshPairedDevices()
        connect()
    }

    func connect() {
        guard let selectedAddress, let selectedPhoneId, !selectedPhoneId.isEmpty else {
            status = "Choose the matching Android device and paired Bluetooth phone."; return
        }
        guard let device = IOBluetoothDevice(addressString: selectedAddress), device.isPaired() else {
            status = "Bluetooth phone is not paired. Pair it in macOS settings, then refresh."; return
        }
        disconnect()
        queryingDevice = device
        status = "Checking \(device.name ?? "Android phone") for Bluetooth calling…"
        let result = device.performSDPQuery(self)
        guard result == kIOReturnSuccess else {
            queryingDevice = nil
            status = "Could not start Bluetooth service discovery (\(result)). Try reconnecting the phone in macOS settings."
            return
        }
        queryTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, self.queryingDevice?.addressString == selectedAddress else { return }
            self.queryingDevice = nil
            self.queryTimeout = nil
            self.status = "Bluetooth service discovery timed out. Check that the phone is nearby and Bluetooth is on."
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status statusCode: IOReturn) {
        update { [weak self] in
            guard let self, let device, self.queryingDevice?.addressString == device.addressString,
                  self.selectedAddress == device.addressString else { return }
            self.queryTimeout?.invalidate(); self.queryTimeout = nil; self.queryingDevice = nil
            guard statusCode == kIOReturnSuccess else {
                self.status = "Bluetooth service discovery failed (\(statusCode)). Check the phone's Bluetooth connection."
                return
            }
            self.refreshPairedDevices()
            guard device.handsFreeAudioGatewayServiceRecord() != nil else {
                self.status = "This phone did not advertise Bluetooth hands-free calling. Check its Bluetooth Calls setting."
                return
            }
            self.startHandsFreeConnection(to: device)
        }
    }

    private func startHandsFreeConnection(to device: IOBluetoothDevice) {
        guard let candidate = IOBluetoothHandsFreeDevice(device: device, delegate: self) else {
            status = "macOS could not create a hands-free connection for this device."; return
        }
        handsFree = candidate
        status = "Connecting to \(device.name ?? "Android phone") over Bluetooth…"
        candidate.connect()
        connectionTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self, weak candidate] _ in
            guard let self, let candidate, self.handsFree === candidate, !candidate.isConnected else { return }
            self.disconnect()
            self.status = "Bluetooth hands-free connection timed out. Check the phone's Bluetooth pairing and Calls switch."
        }
    }

    func disconnect() {
        queryTimeout?.invalidate(); queryTimeout = nil; queryingDevice = nil
        connectionTimeout?.invalidate(); connectionTimeout = nil
        callCommandTimeout?.invalidate(); callCommandTimeout = nil; pendingCallCommand = nil
        handsFree?.disconnect()
        handsFree = nil
        isConnected = false; isCallActive = false; callSetupMode = 0
        incomingNumber = nil
        status = "Bluetooth calling disconnected."
    }

    @discardableResult func answerOnMac() -> Bool {
        guard canAnswer, let handsFree else { status = "No incoming Bluetooth call is available to answer."; return false }
        status = "Answer requested. Waiting for the phone's call state…"
        watchCallCommand("answer")
        handsFree.acceptCall()
        return true
    }

    @discardableResult func endCall() -> Bool {
        guard canEnd, let handsFree else { status = "No Bluetooth call is available to end."; return false }
        status = "End requested. Waiting for the phone's call state…"
        watchCallCommand("end")
        handsFree.endCall()
        return true
    }

    private func update(_ change: @escaping () -> Void) {
        if Thread.isMainThread { change() } else { DispatchQueue.main.async(execute: change) }
    }

    private func watchCallCommand(_ command: String) {
        callCommandTimeout?.invalidate()
        pendingCallCommand = command
        callCommandTimeout = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, self.pendingCallCommand == command else { return }
            self.handsFree?.currentCallList()
            self.pendingCallCommand = nil
            self.callCommandTimeout = nil
            self.status = command == "answer"
                ? "Answer was sent over Bluetooth, but the phone has not confirmed an active call. Check the phone."
                : "End was sent over Bluetooth, but the phone has not confirmed the call ended. Check the phone."
        }
    }

    private func confirmCallCommand(_ command: String) {
        guard pendingCallCommand == command else { return }
        callCommandTimeout?.invalidate(); callCommandTimeout = nil; pendingCallCommand = nil
        status = command == "answer" ? "Phone confirmed the call is active." : "Phone confirmed the call ended."
    }

    func handsFree(_ device: IOBluetoothHandsFree!, connected statusCode: NSNumber!) {
        update { [weak self] in
            guard let self, self.handsFree === device else { return }
            self.connectionTimeout?.invalidate(); self.connectionTimeout = nil
            self.isConnected = statusCode.intValue == 0 && device.isConnected
            self.status = self.isConnected ? "Bluetooth hands-free connected to \(self.selectedDeviceName)." : "Bluetooth hands-free connection failed (\(statusCode.intValue))."
            if self.isConnected { self.handsFree?.currentCallList() }
        }
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected statusCode: NSNumber!) {
        update { [weak self] in
            guard let self, self.handsFree === device else { return }
            self.isConnected = false; self.isCallActive = false; self.callSetupMode = 0
            self.callCommandTimeout?.invalidate(); self.callCommandTimeout = nil; self.pendingCallCommand = nil
            self.status = "Bluetooth hands-free disconnected (\(statusCode.intValue))."
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode mode: NSNumber!) {
        update { [weak self] in
            guard let self, self.handsFree === device else { return }
            self.callSetupMode = mode.intValue
            if mode.intValue == 1 { self.status = "Incoming Bluetooth call from \(self.incomingNumber ?? "your Android phone")." }
            else if mode.intValue == 2 { self.status = "Dialing on your Android phone…" }
            else if mode.intValue == 3 { self.status = "Waiting for the other phone to answer…" }
            else if mode.intValue == 0 && !self.isCallActive {
                self.incomingNumber = nil
                if self.pendingCallCommand == "end" { self.confirmCallCommand("end") }
                else { self.status = "No Bluetooth call in progress." }
            }
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive active: NSNumber!) {
        update { [weak self] in
            guard let self, self.handsFree === device else { return }
            self.isCallActive = active.boolValue
            if active.boolValue {
                if self.pendingCallCommand == "answer" { self.confirmCallCommand("answer") }
                else { self.status = "Bluetooth call active." }
            } else if self.callSetupMode == 0 {
                self.incomingNumber = nil
                if self.pendingCallCommand == "end" { self.confirmCallCommand("end") }
                else { self.status = "Bluetooth call ended." }
            }
        }
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        update { [weak self] in
            guard let self, self.handsFree === device else { return }
            self.incomingNumber = number
            self.status = "Incoming Bluetooth call from \(number ?? "unknown number")."
        }
    }
}
