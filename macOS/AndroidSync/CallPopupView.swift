import SwiftUI
import AppKit

struct CallQuickReply: Identifiable {
    let id: String
    let text: String
    static let defaults = [
        CallQuickReply(id: "meeting", text: "I'm in a meeting"),
        CallQuickReply(id: "hour", text: "I'll call you in an hour"),
        CallQuickReply(id: "later", text: "Can't talk right now")
    ]
}

struct CallControlButtons: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bluetoothCalls: BluetoothCalls
    let item: PhoneNotification
    var customMessage: ((CallNotificationAction) -> Void)?
    var compact = false

    private func action(_ kind: String) -> CallNotificationAction? { item.callActions?.first { $0.kind == kind } }
    private var disabled: Bool { !model.notificationDeviceConnected(item) || model.commandStates[item.id] == "sending" }
    private func useBluetooth(_ kind: String) -> Bool {
        guard item.deviceId == bluetoothCalls.selectedPhoneId else { return false }
        return kind == "answer" ? bluetoothCalls.canAnswer : kind == "decline" && bluetoothCalls.canEnd
    }

    var body: some View {
        HStack(spacing: compact ? 7 : 8) {
            control(kind: "answer", title: compact ? "Accept" : "Accept Call", symbol: "phone.fill", tint: AppTheme.teal)
            control(kind: "decline", title: declineTitle, symbol: "phone.down.fill", tint: .red)
            control(kind: "mute", title: action("mute")?.title.localizedCaseInsensitiveContains("unmute") == true ? "Unmute" : "Mute", symbol: "mic.slash.fill", tint: AppTheme.blue)
            Menu {
                ForEach(CallQuickReply.defaults) { reply in
                    Button(reply.text) { sendQuickReply(reply.text) }
                }
                if let message = action("declineMessage"), let customMessage {
                    Divider()
                    Button("Custom message…") { customMessage(message) }
                }
            } label: {
                Label(compact ? "Reply" : "Reply & Decline", systemImage: "message.fill")
            }
            .disabled(action("declineMessage") == nil || disabled)
            .help(action("declineMessage") == nil ? "The phone app does not offer decline with message for this call." : "Send a quick reply and decline the call")
        }
    }

    @ViewBuilder private func control(kind: String, title: String, symbol: String, tint: Color) -> some View {
        let exposed = action(kind)
        let overBluetooth = useBluetooth(kind)
        Button(role: kind == "decline" ? .destructive : nil) {
            if overBluetooth {
                if kind == "answer" { bluetoothCalls.answerOnMac() }
                else { bluetoothCalls.endCall() }
                return
            }
            guard let exposed else { return }
            model.sendAction(key: item.id, kind: "call", actionId: exposed.id, expectedTimestamp: item.timestamp)
        } label: {
            Label(title, systemImage: symbol)
        }
        .tint(tint)
        .disabled(!overBluetooth && (exposed == nil || disabled))
        .help(overBluetooth ? "Use the connected Bluetooth hands-free call" : exposed == nil ? "The phone app does not offer this control for the current call." : title)
    }

    private var declineTitle: String {
        if useBluetooth("decline") { return bluetoothCalls.isCallActive ? "End Call" : "Decline" }
        guard let decline = action("decline") else { return compact ? "Decline" : "Decline Call" }
        if decline.title.localizedCaseInsensitiveContains("end") || item.callState == "ongoing" { return "End Call" }
        return compact ? "Decline" : "Decline Call"
    }

    private func sendQuickReply(_ text: String) {
        guard let message = action("declineMessage") else { return }
        model.sendAction(key: item.id, kind: "call", text: text, actionId: message.id, expectedTimestamp: item.timestamp)
    }
}

struct CallPopupView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bluetoothCalls: BluetoothCalls
    @Environment(\.colorScheme) private var colorScheme
    let notificationId: String

    private var item: PhoneNotification? { model.notifications.first { $0.id == notificationId } }

    var body: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        callerAvatar(item)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.callDisplayName(for: item)).font(.title2.weight(.semibold)).lineLimit(1).streamSensitive()
                            if let number = model.callDisplayNumber(for: item), number != model.callDisplayName(for: item) {
                                Text(number).font(.callout).foregroundStyle(.secondary).lineLimit(1).streamSensitive()
                            }
                            Text(callSubtitle(item)).font(.callout).foregroundStyle(AppTheme.teal)
                        }
                        Spacer()
                        Button { model.dismissCallPopup(item.id, timestamp: item.timestamp) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Hide call controls on this Mac")
                    }
                    CallControlButtons(item: item, compact: true)
                        .environmentObject(model)
                    if (item.callActions ?? []).count < 4 && bluetoothCalls.selectedPhoneId != item.deviceId {
                        Text("Dimmed controls aren’t provided by this phone app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Call controls work on Mac; call audio remains on your phone.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                    if bluetoothCalls.selectedPhoneId == item.deviceId && bluetoothCalls.isConnected {
                        Text(bluetoothCalls.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let detail = model.commandDetails[item.id] {
                        Text(detail).font(.caption).foregroundStyle(model.commandStates[item.id] == "failed" ? Color.red : Color.secondary).lineLimit(2)
                    }
                }
                .padding(18)
                .background(AppTheme.card(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.blue.opacity(0.65), lineWidth: 1))
                .padding(1)
            }
        }
        .frame(width: 440)
    }

    @ViewBuilder private func callerAvatar(_ item: PhoneNotification) -> some View {
        if let image = model.callCallerImage(for: item) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 62, height: 62).clipShape(Circle()).streamSensitive(strongBlur: true)
        } else {
            Text(initials(model.callDisplayName(for: item))).font(.title2.bold()).foregroundStyle(.white)
                .frame(width: 62, height: 62).background(LinearGradient(colors: [AppTheme.blue, AppTheme.teal], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle()).streamSensitive()
        }
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }

    private func callSubtitle(_ item: PhoneNotification) -> String {
        let state = item.callState == "ongoing" ? "Call in progress" : item.callState == "screening" ? "Screening call" : item.callState == "incoming" ? "Incoming call" : "Call · status unavailable"
        return "\(state) · \(item.app)"
    }
}

struct BluetoothIncomingCallPopup: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bluetoothCalls: BluetoothCalls
    @Environment(\.colorScheme) private var colorScheme

    private var caller: String {
        guard let number = bluetoothCalls.incomingNumber, !number.isEmpty else { return "Incoming cellular call" }
        let digits = String(number.filter(\.isNumber))
        let contact = model.contacts.first { contact in
            guard contact.deviceId == bluetoothCalls.selectedPhoneId else { return false }
            return contact.phones.contains { phone in
                let other = String(phone.filter(\.isNumber))
                let length = min(10, min(digits.count, other.count))
                return length >= 7 && digits.suffix(length) == other.suffix(length)
            }
        }
        return contact?.name ?? number
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "phone.arrow.down.left.fill").font(.title2).foregroundStyle(AppTheme.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(caller).font(.title2.bold()).lineLimit(1).streamSensitive()
                    Text("Bluetooth call · \(bluetoothCalls.selectedDeviceName)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.dismissBluetoothCallPopup() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            HStack {
                Button("Answer call", systemImage: "phone.fill") { bluetoothCalls.answerOnMac() }
                    .tint(AppTheme.teal).disabled(!bluetoothCalls.canAnswer)
                Button("Decline", systemImage: "phone.down.fill", role: .destructive) { bluetoothCalls.endCall() }
                    .disabled(!bluetoothCalls.canEnd)
            }
            Text(bluetoothCalls.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Call audio stays on your phone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(AppTheme.card(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.blue.opacity(0.65)))
        .padding(1)
        .frame(width: 440)
    }
}

@MainActor final class CallPopupController {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var suppressed: [String: Int64] = [:]
    private var suppressBluetoothUntilIdle = false

    init(model: AppModel) { self.model = model }

    func refresh() {
        guard let model else { hide(); return }
        if model.bluetoothCalls.callSetupMode != 1 { suppressBluetoothUntilIdle = false }
        let root: AnyView
        if let item = model.activeCallNotification, suppressed[item.id] != item.timestamp {
            root = AnyView(CallPopupView(notificationId: item.id).environmentObject(model).environmentObject(model.bluetoothCalls).tint(AppTheme.blue).buttonStyle(AppNeutralButtonStyle()))
        } else if model.bluetoothCalls.canAnswer && !suppressBluetoothUntilIdle {
            root = AnyView(BluetoothIncomingCallPopup().environmentObject(model).environmentObject(model.bluetoothCalls).tint(AppTheme.blue).buttonStyle(AppNeutralButtonStyle()))
        } else { hide(); return }
        if let hosting { hosting.rootView = root }
        else {
            let hosting = NSHostingView(rootView: root); self.hosting = hosting
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 210), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = hosting
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            self.panel = panel
        }
        hosting?.layoutSubtreeIfNeeded()
        if let fitting = hosting?.fittingSize { panel?.setContentSize(NSSize(width: 440, height: max(190, fitting.height))) }
        position(); panel?.orderFrontRegardless()
    }

    func dismiss(id: String, timestamp: Int64) { suppressed[id] = timestamp; hide() }
    func dismissBluetooth() { suppressBluetoothUntilIdle = true; hide() }

    private func position() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 22, y: frame.minY + 22))
    }

    private func hide() { panel?.orderOut(nil) }
}
