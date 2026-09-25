import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppTheme {
    static let blue = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)       // #3b82f6
    static let teal = Color(red: 31 / 255, green: 182 / 255, blue: 166 / 255)       // #1fb6a6
    static let lightCanvas = Color(red: 223 / 255, green: 231 / 255, blue: 239 / 255) // #dfe7ef
    static let darkCanvas = Color(red: 0 / 255, green: 23 / 255, blue: 41 / 255)     // #001729
    static let darkSidebar = Color(red: 4 / 255, green: 30 / 255, blue: 47 / 255)    // #041e2f
    static let darkCard = Color(red: 12 / 255, green: 39 / 255, blue: 59 / 255)      // #0c273b

    static func canvas(for scheme: ColorScheme) -> Color { scheme == .dark ? darkCanvas : lightCanvas }
    static func sidebar(for scheme: ColorScheme) -> Color { scheme == .dark ? darkSidebar : lightCanvas }
    static func card(for scheme: ColorScheme) -> Color { scheme == .dark ? darkCard : .white }
}

struct AppNeutralButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground(for: configuration.role))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.card(for: colorScheme).opacity(isEnabled ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.blue.opacity(isEnabled ? 1 : 0.32), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    private func foreground(for role: ButtonRole?) -> Color {
        guard isEnabled else { return .secondary }
        return role == .destructive ? .red : AppTheme.blue
    }
}

struct AppProgressBar: View {
    let value: Double?
    @State private var phase: CGFloat = -0.3

    init(value: Double? = nil) {
        self.value = value
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let fraction = min(1, max(0, value ?? 0))
            let segmentWidth = max(22, width * 0.28)

            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.darkCanvas)
                Capsule()
                    .fill(AppTheme.teal)
                    .frame(width: value == nil ? segmentWidth : width * fraction)
                    .offset(x: value == nil ? phase * (width + segmentWidth) : 0)
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(AppTheme.darkCanvas, lineWidth: 1))
        }
        .frame(height: 8)
        .onAppear {
            guard value == nil else { return }
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

struct AppGroupBoxStyle: GroupBoxStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content
        }
        .padding(16)
        .background(AppTheme.card(for: colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)))
    }
}

struct AppCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(AppTheme.card(for: colorScheme), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)))
    }
}

extension View {
    func appCard() -> some View { modifier(AppCardModifier()) }
    func streamSensitive(strongBlur: Bool = false) -> some View { modifier(StreamSensitiveModifier(strongBlur: strongBlur)) }
}

private struct StreamSensitiveModifier: ViewModifier {
    @AppStorage("streamModeEnabled") private var enabled = false
    @State private var hovered = false
    let strongBlur: Bool

    func body(content: Content) -> some View {
        let hidden = enabled && !hovered
        content
            .blur(radius: hidden ? (strongBlur ? 18 : 8) : 0)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .help(enabled ? "Hover to reveal this item" : "")
    }
}

enum Page: String, CaseIterable, Identifiable {
    case notifications = "Notifications", messages = "Messages", contacts = "Contacts", calls = "Call History", photos = "Photo", files = "Files", fileTransfer = "File Transfer", clipboard = "Clipboard", devices = "Devices", mirror = "Mirror Devices", settings = "Settings"
    var id: String { rawValue }
    var symbol: String { switch self { case .notifications: "bell"; case .messages: "message"; case .contacts: "person.crop.circle"; case .calls: "phone"; case .photos: "photo.on.rectangle.angled"; case .files: "folder"; case .fileTransfer: "arrow.up.arrow.down.circle"; case .clipboard: "doc.on.clipboard"; case .devices: "desktopcomputer"; case .mirror: "rectangle.inset.filled.and.person.filled"; case .settings: "gearshape" } }
}
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("streamModeEnabled") private var streamModeEnabled = false
    @State private var selection: Page? = .notifications
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: "AndroidSync")!)
                        .resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
                    VStack(alignment: .leading) { Text("Android Sync").font(.headline); Text("Your devices, together").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 18)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        SidebarGroup(title: "Communication", pages: [.notifications, .messages, .contacts, .calls], selection: $selection)
                        SidebarGroup(title: "Content", pages: [.photos, .files, .fileTransfer, .clipboard], selection: $selection)
                        SidebarGroup(title: "Devices", pages: [.devices, .mirror], selection: $selection)
                        SidebarGroup(title: "Application", pages: [.settings], selection: $selection)
                    }.padding(.horizontal, 10).padding(.bottom, 16)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.onlineName, systemImage: model.connected.isEmpty ? "circle" : "checkmark.circle.fill").foregroundStyle(model.connected.isEmpty ? Color.secondary : AppTheme.teal)
                    Text("Private local connection").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.card(for: colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.72), in: RoundedRectangle(cornerRadius: 12))
                .padding(10)
            }
            .background(AppTheme.sidebar(for: colorScheme).ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 280)
        } detail: {
            Group {
                switch selection ?? .notifications {
                case .notifications: NotificationsView()
                case .messages: MessagesView()
                case .contacts: ContactsView()
                case .calls: CallHistoryView()
                case .photos: PhotosView()
                case .files: FilesView()
                case .fileTransfer: FileTransferView()
                case .mirror: MirroringView()
                case .clipboard: ClipboardView()
                case .devices: DevicesView()
                case .settings: ScrollView { SettingsView().padding(28) }
                }
            }
            .background(AppTheme.canvas(for: colorScheme).ignoresSafeArea())
            .toolbar {
                if streamModeEnabled { ToolbarItem { Label("Stream Mode", systemImage: "eye.slash.fill").foregroundStyle(AppTheme.teal).help("Sensitive items are blurred until hovered") } }
                ToolbarItem { Label(model.connected.isEmpty ? "Offline" : "Connected", systemImage: model.connected.isEmpty ? "wifi.slash" : "wifi").foregroundStyle(model.connected.isEmpty ? Color.secondary : AppTheme.teal) }
            }
        }
        .tint(AppTheme.blue)
        .buttonStyle(AppNeutralButtonStyle())
        .groupBoxStyle(AppGroupBoxStyle())
        .onChange(of: model.requestedSection) { _, section in if let section, let page = Page(rawValue: section) { selection = page; model.requestedSection = nil } }
        .alert("Android Sync", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
struct SidebarGroup: View {
    let title: String
    let pages: [Page]
    @Binding var selection: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ForEach(pages) { page in
                Button {
                    selection = page
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol)
                            .frame(width: 18)
                            .foregroundStyle(selection == page ? Color.white : AppTheme.teal)
                        Text(page.rawValue).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.weight(selection == page ? .semibold : .regular))
                    .foregroundStyle(selection == page ? Color.white : Color.primary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(selection == page ? AppTheme.blue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == page ? .isSelected : [])
            }
        }
    }
}
struct SectionHeading: View {
    let title: String; let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
}
struct EmptyPanel: View {
    let symbol: String; let title: String; let subtitle: String
    var body: some View {
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(subtitle).frame(maxWidth: 360) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct NotificationsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var showDismissed = false
    var filtered: [PhoneNotification] {
        model.notifications.filter { !model.excluded.contains($0.package) && (showDismissed || $0.localDismissed != true) && (query.isEmpty || "\($0.app) \($0.title) \($0.text)".localizedCaseInsensitiveContains(query)) }.sorted { $0.timestamp > $1.timestamp }
    }
    var body: some View {
        VStack(spacing: 20) {
            SectionHeading(title: "Notifications", subtitle: "Read and reply without reaching for your phone.")
            NotificationSetupStatus()
            HStack { TextField("Search notifications", text: $query).textFieldStyle(.roundedBorder); Toggle("Show dismissed", isOn: $showDismissed).toggleStyle(.checkbox); Button("Clear history") { model.clearHistory() } }
            if filtered.isEmpty { EmptyPanel(symbol: "bell.badge", title: "A quieter way to stay connected", subtitle: "Pair your phone and enable notification access. Your Android alerts will appear here and in Notification Center.") }
            else { ScrollView { LazyVStack(spacing: 12) { ForEach(filtered) { item in NotificationCard(item: item) } } } }
        }.padding(28)
    }
}
struct NotificationCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject private var bluetoothCalls: BluetoothCalls
    let item: PhoneNotification
    @State private var reply = ""
    @State private var replying = false
    @State private var replyTimestamp: Int64?
    @State private var callMessageAction: CallNotificationAction?
    @State private var callMessage = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let icon = model.notificationAppIcon(for: item) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: item.reply ? "bubble.left.and.bubble.right.fill" : "app.fill").foregroundStyle(AppTheme.teal).frame(width: 34, height: 34).background(AppTheme.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }
                Text(item.app).font(.subheadline.weight(.semibold)).streamSensitive(); if let device = model.notificationDeviceName(item) { Text("· \(device)").font(.caption).foregroundStyle(.secondary).streamSensitive() }; if !item.active { Text("History").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                Button { model.dismissLocal(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss on this Mac")
            }
            if !item.title.isEmpty { Text(item.title).font(.headline).streamSensitive() }
            Text(item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).streamSensitive()
            if item.active, item.call == true || !(item.callActions ?? []).isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    CallControlButtons(item: item, customMessage: { action in callMessage = ""; callMessageAction = action })
                    Text("Call controls work on Mac; call audio remains on your phone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if item.active && item.reply { Button("Reply", systemImage: "arrowshape.turn.up.left") { replyTimestamp = item.timestamp; replying.toggle() }.disabled(!model.notificationDeviceConnected(item) || model.commandStates[item.id] == "sending") }
                ForEach(item.links.filter { SyncRules.validWebURL($0) != nil }, id: \.self) { link in Button("Open link", systemImage: "arrow.up.right.square") { if let url = SyncRules.validWebURL(link) { NSWorkspace.shared.open(url) } } }
                Menu("More") {
                    if item.active {
                        Button("Dismiss on phone") { model.sendAction(key: item.id, kind: "dismiss") }
                        ForEach(item.actions, id: \.id) { action in Button("On phone: \(action.title)") { model.sendAction(key: item.id, kind: "action", actionId: action.id) } }
                    }
                    Button("Exclude \(item.app)") { model.excludeApp(item.package) }
                }
                Spacer()
                if let state = model.commandStates[item.id] { Text(state == "accepted" ? "Action accepted by Android" : state == "sending" ? "Sending…" : state == "uncertain" ? "Result uncertain" : "Action failed").font(.caption).foregroundStyle(state == "failed" ? .red : .secondary) }
            }
            if let detail = model.commandDetails[item.id] { Text(detail).font(.caption).foregroundStyle(model.commandStates[item.id] == "failed" ? Color.red : Color.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            if !item.active && item.reply { Text("This notification is no longer active on your phone. Replies are unavailable.").font(.caption).foregroundStyle(.secondary) }
            if replying && item.active && item.reply {
                if replyTimestamp != item.timestamp {
                    Text("The phone notification changed while you were writing. Review its latest content above.").font(.caption).foregroundStyle(.secondary)
                    Button("Reply to latest notification") { replyTimestamp = item.timestamp }
                }
                HStack {
                    TextField("Write a reply…", text: $reply).textFieldStyle(.roundedBorder).onSubmit { submitReply() }.disabled(model.commandStates[item.id] == "sending").streamSensitive()
                    Button("Send") { submitReply() }.buttonStyle(.borderedProminent).disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.commandStates[item.id] == "sending" || replyTimestamp != item.timestamp || !model.notificationDeviceConnected(item))
                }
            }
        }.padding(18).appCard().onChange(of: model.commandStates[item.id]) { _, state in
            if state == "accepted" { reply = ""; replying = false; callMessage = ""; callMessageAction = nil }
        }
        .sheet(item: $callMessageAction) { action in
            VStack(alignment: .leading, spacing: 16) {
                Text("Decline with Message").font(.title2.weight(.semibold))
                Text("The phone's calling app will receive this message and decline the active call.").foregroundStyle(.secondary)
                TextEditor(text: $callMessage).font(.body).padding(6).frame(minHeight: 120, maxHeight: 220).overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.blue)).streamSensitive()
                HStack {
                    Spacer()
                    Button("Cancel") { callMessage = ""; callMessageAction = nil }
                    Button("Send and Decline") {
                        model.sendAction(key: item.id, kind: "call", text: callMessage, actionId: action.id, expectedTimestamp: item.timestamp)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(callMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.commandStates[item.id] == "sending" || !model.notificationDeviceConnected(item))
                }
            }.padding(22).frame(width: 460)
        }
    }
    private func submitReply() { guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, replyTimestamp == item.timestamp else { return }; model.sendAction(key: item.id, kind: "reply", text: reply, expectedTimestamp: replyTimestamp) }
}
struct ClipboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var link = ""
    @State private var query = ""
    @State private var selectedDeviceId: String?
    @State private var confirmingClear = false
    private var clips: [ClipboardRecord] { model.clipboardRecords(deviceId: selectedDeviceId, query: query) }
    private var selectedName: String { selectedDeviceId.flatMap { id in model.clipboardDevices.first(where: { $0.id == id })?.name } ?? "All devices" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { SectionHeading(title: "Clipboard", subtitle: "Text, links, and images across your connected devices."); Button(model.clipboardPaused ? "Resume sync" : "Pause sync", systemImage: model.clipboardPaused ? "play" : "pause") { model.toggleClipboard() } }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ClipboardDeviceTab(title: "All devices", symbol: "square.stack.3d.up", connected: nil, selected: selectedDeviceId == nil) { selectedDeviceId = nil }
                        ForEach(model.clipboardDevices) { device in
                            ClipboardDeviceTab(title: device.name, symbol: device.local ? "macbook" : "iphone", connected: device.connected, selected: selectedDeviceId == device.id) { selectedDeviceId = device.id }
                        }
                    }.padding(.vertical, 2)
                }
                if let selectedDeviceId {
                    Button(model.pausedClipboardDevices.contains(selectedDeviceId) ? "Resume \(selectedName)" : "Pause \(selectedName)",systemImage: model.pausedClipboardDevices.contains(selectedDeviceId) ? "play" : "pause") {
                        model.toggleClipboardDevice(selectedDeviceId)
                    }
                }
                HStack {
                    TextField("Search \(selectedName.lowercased()) clipboard", text: $query).textFieldStyle(.roundedBorder)
                    Text("\(clips.count) \(clips.count == 1 ? "clip" : "clips")").foregroundStyle(.secondary).monospacedDigit()
                    Button("Clear \(selectedDeviceId == nil ? "all" : "tab")", systemImage: "trash", role: .destructive) { confirmingClear = true }.disabled(model.clipboardRecords(deviceId: selectedDeviceId, query: "").isEmpty)
                }
                HStack {
                    Text("Encrypted history: \(ByteCountFormatter.string(fromByteCount: model.clipboardStorageBytes,countStyle: .file))").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Per-device quota",selection: Binding(get: { model.clipboardQuotaBytes },set: model.setClipboardQuota)) {
                        Text("256 MB").tag(Int64(256 * 1024 * 1024))
                        Text("1 GB").tag(Int64(1024 * 1024 * 1024))
                        Text("2 GB").tag(Int64(2 * 1024 * 1024 * 1024))
                    }.pickerStyle(.segmented).frame(width: 300)
                }.font(.caption)
                if clips.isEmpty {
                    ContentUnavailableView("No clipboard items", systemImage: "doc.on.clipboard", description: Text(query.isEmpty ? "Copied text, links, and images from \(selectedName.lowercased()) will stay available here, even when that device is offline or removed." : "Try a different search."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(clips) { record in ClipboardRecordCard(record: record) }
                    }
                }
                GroupBox("Share a snippet") { VStack(alignment: .leading) { TextEditor(text: $text).frame(height: 90).streamSensitive(); Button("Send text", systemImage: "paperplane") { model.shareText(text); text = "" }.disabled(model.connected.isEmpty || model.clipboardPaused || text.isEmpty) }.padding(8) }
                GroupBox("Share a link") { HStack { TextField("https://…", text: $link).streamSensitive(); Button("Send link") { model.shareLink(link); link = "" }.disabled(model.connected.isEmpty) }.padding(10) }
                if !model.receivedLinks.isEmpty { GroupBox("Received links") { VStack(alignment: .leading, spacing: 12) { ForEach(model.receivedLinks, id: \.self) { link in HStack { Text(link).lineLimit(1).streamSensitive(); Spacer(); Button("Open") { if let url = SyncRules.validWebURL(link) { NSWorkspace.shared.open(url) } } } } }.padding(8) } }
            }.padding(28)
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
            Button("Clear \(selectedDeviceId == nil ? "all devices" : selectedName)", role: .destructive) { model.clearClipboardHistory(deviceId: selectedDeviceId) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes the encrypted clipboard items in the selected tab from this Mac.") }
        .onChange(of: model.clipboardDevices.map(\.id)) { _, ids in if let selectedDeviceId, !ids.contains(selectedDeviceId) { self.selectedDeviceId = nil } }
    }
}
struct ClipboardDeviceTab: View {
    let title: String
    let symbol: String
    let connected: Bool?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title).lineLimit(1).streamSensitive()
                if let connected { Circle().fill(connected ? AppTheme.teal : .secondary.opacity(0.55)).frame(width: 7, height: 7).accessibilityLabel(connected ? "Connected" : "Offline") }
            }
            .font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AppTheme.blue : Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain)
    }
}
struct ClipboardRecordCard: View {
    @EnvironmentObject var model: AppModel
    let record: ClipboardRecord
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: record.isImage ? "photo" : record.isLink ? "link" : "doc.text").foregroundStyle(AppTheme.teal).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.deviceName).font(.headline).streamSensitive()
                    Text(record.sourceApp == "Source unavailable" ? record.origin : "\(record.sourceApp) · \(record.origin)").font(.caption).foregroundStyle(.secondary).lineLimit(1).streamSensitive()
                }
                Spacer()
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            if record.isImage {
                if let image = model.clipboardImage(for: record) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 300).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10)).streamSensitive(strongBlur: true) }
                else { Label("Image unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90) }
                if let width = record.width, let height = record.height { Text("\(width) × \(height)").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(record.text).textSelection(.enabled).lineLimit(8).frame(maxWidth: .infinity, alignment: .leading).streamSensitive()
            }
            HStack {
                Button(copied ? "Copied" : record.isImage ? "Copy image" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    model.copyClipboardRecord(record); copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }.buttonStyle(.borderedProminent)
                if record.isLink { Button("Open", systemImage: "arrow.up.right.square") { if let url = SyncRules.validWebURL(record.text) { NSWorkspace.shared.open(url) } } }
                Spacer()
                Button(record.pinned == true ? "Unpin" : "Pin", systemImage: "pin") { model.toggleClipboardPin(record) }.labelStyle(.iconOnly).help(record.pinned == true ? "Unpin clipboard item" : "Keep this item during quota cleanup")
                Menu {
                    Button("Delete on this Mac",systemImage: "trash",role: .destructive) { model.removeClipboardRecord(record) }
                    Button("Delete everywhere",systemImage: "trash.slash",role: .destructive) { model.deleteClipboardEverywhere(record) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).help("Clipboard actions")
            }
        }.padding(16).appCard()
    }
}
struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selectedPhoneId: String?
    @State private var selectedThreadId: String?
    @State private var draft = ""
    @State private var showComposer = false
    @State private var composeAddress = ""
    @State private var composePhoneId: String?
    @State private var lastCommandId: String?
    private var threads: [SmsThreadRecord] {
        model.smsThreads.filter { thread in
            (selectedPhoneId == nil || thread.deviceId == selectedPhoneId) && (query.isEmpty || "\(thread.contactName ?? "") \(thread.address) \(thread.snippet)".localizedCaseInsensitiveContains(query))
        }
    }
    private var selectedThread: SmsThreadRecord? { model.smsThreads.first { $0.id == selectedThreadId } }
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            SectionHeading(title: "Messages",subtitle: "Browse carrier SMS and send through your Android phone.")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    Picker("Device",selection: $selectedPhoneId) {
                        Text("All devices").tag(String?.none)
                        ForEach(model.phones) { phone in Text(phone.name).tag(Optional(phone.id)) }
                    }
                    .frame(width: 230)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    TextField("Search messages",text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180, maxWidth: .infinity)
                    Button("Refresh",systemImage: "arrow.clockwise") { model.refreshMessages(phoneId: selectedPhoneId) }
                        .disabled(model.connected.isEmpty)
                    Button("New message",systemImage: "square.and.pencil") { composePhoneId = selectedPhoneId ?? model.connected.sorted().first; composeAddress = ""; showComposer = true }
                        .disabled(model.connected.isEmpty)
                    Menu {
                        Button("Clear all cached messages",role: .destructive) { model.clearMessageCache() }
                        if let selectedPhoneId { Button("Clear selected device",role: .destructive) { model.clearMessageCache(phoneId: selectedPhoneId) } }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if let selectedPhoneId, let status = model.smsStatus[selectedPhoneId] { Text(status).font(.callout).foregroundStyle(status.localizedCaseInsensitiveContains("synchronized") ? AppTheme.teal : .secondary) }
            conversationLayout
        }.padding(28)
        .sheet(isPresented: $showComposer) { SmsComposer(phoneId: $composePhoneId,address: $composeAddress) }
        .onChange(of: selectedPhoneId) { _, _ in selectedThreadId = nil }
    }
    private var conversationLayout: some View {
        HSplitView {
            List(threads,selection: $selectedThreadId) { thread in
                VStack(alignment: .leading,spacing: 5) {
                    HStack { Text(thread.contactName ?? thread.address).font(.headline).lineLimit(1).streamSensitive(); Spacer(); if thread.unreadCount > 0 { Text("\(thread.unreadCount)").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,3).background(AppTheme.blue,in: Capsule()).streamSensitive() } }
                    Text(thread.snippet).lineLimit(2).foregroundStyle(.secondary).streamSensitive()
                    HStack { Text(model.phones.first(where: { $0.id == thread.deviceId })?.name ?? "Removed device"); Spacer(); Text(Date(timeIntervalSince1970: Double(thread.timestamp) / 1000),style: .relative) }.font(.caption).foregroundStyle(.tertiary)
                }.padding(.vertical,6).tag(thread.id)
            }.frame(minWidth: 220,idealWidth: 280,maxWidth: 340)
            if let thread = selectedThread { conversation(thread) }
            else { EmptyPanel(symbol: "message",title: threads.isEmpty ? "No carrier SMS cached" : "Choose a conversation",subtitle: threads.isEmpty ? "Enable Carrier SMS and contacts for this Mac on Android, then refresh." : "Messages stay encrypted on this Mac until you clear them or revoke access.") }
        }
    }
    private func conversation(_ thread: SmsThreadRecord) -> some View {
        let messages = model.smsMessages.filter { $0.threadId == thread.id }
        let bottomId = "sms-bottom-\(thread.id)"
        return VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(thread.contactName ?? thread.address).font(.title2.bold()).streamSensitive()
                    Text(thread.address).foregroundStyle(.secondary).streamSensitive()
                }
                Spacer()
                Text(model.phones.first(where: { $0.id == thread.deviceId })?.name ?? "Android").font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { message in
                            HStack {
                                if message.outgoing { Spacer(minLength: 80) }
                                VStack(alignment: .leading,spacing: 5) {
                                    Text(message.body).textSelection(.enabled).streamSensitive()
                                    Text(Date(timeIntervalSince1970: Double(message.timestamp) / 1000),format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(message.outgoing ? AppTheme.blue.opacity(0.16) : Color.secondary.opacity(0.12),in: RoundedRectangle(cornerRadius: 12))
                                if !message.outgoing { Spacer(minLength: 80) }
                            }
                        }
                        Color.clear.frame(height: 1).id(bottomId)
                    }
                    .padding()
                }
                .onAppear { scrollToLatest(proxy,bottomId: bottomId,animated: false) }
                .onChange(of: thread.id) { _, _ in scrollToLatest(proxy,bottomId: bottomId,animated: false) }
                .onChange(of: messages.last?.id) { _, _ in scrollToLatest(proxy,bottomId: bottomId,animated: true) }
            }
            Divider()
            HStack(alignment: .bottom) { TextField("Carrier SMS",text: $draft,axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).streamSensitive(); Button("Send",systemImage: "paperplane.fill") { send(to: thread) }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thread.deviceId.map { !model.connected.contains($0) } != false) }
            if let command = lastCommandId, let state = model.smsCommandStates[command] { Text(model.smsCommandDetails[command] ?? state).font(.caption).foregroundStyle(state == "accepted" ? AppTheme.teal : state == "failed" ? .red : .orange).frame(maxWidth: .infinity,alignment: .leading) }
        }.padding().frame(minWidth: 300)
    }
    private func scrollToLatest(_ proxy: ScrollViewProxy, bottomId: String, animated: Bool) {
        DispatchQueue.main.async {
            if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomId,anchor: .bottom) } }
            else { proxy.scrollTo(bottomId,anchor: .bottom) }
        }
    }
    private func send(to thread: SmsThreadRecord) {
        guard let phoneId = thread.deviceId, let command = model.sendSMS(phoneId: phoneId,address: thread.address,body: draft) else { return }
        lastCommandId = command; draft = ""
    }
}

struct ContactsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var selectedPhoneId: String?
    @State private var showComposer = false
    @State private var composeAddress = ""
    @State private var composePhoneId: String?

    private var visibleContacts: [ContactRecord] {
        model.contacts.filter { contact in
            (selectedPhoneId == nil || contact.deviceId == selectedPhoneId) &&
            (query.isEmpty || "\(contact.name) \(contact.phones.joined(separator: " "))".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Contacts", subtitle: "Browse contacts from your Android devices and start a carrier call or SMS.")
            HStack(spacing: 12) {
                Picker("Device", selection: $selectedPhoneId) {
                    Text("All devices").tag(String?.none)
                    ForEach(model.phones) { phone in Text(phone.name).tag(Optional(phone.id)) }
                }.frame(width: 230)
                TextField("Search contacts", text: $query).textFieldStyle(.roundedBorder)
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshMessages(phoneId: selectedPhoneId) }
                    .disabled(model.connected.isEmpty)
            }
            if visibleContacts.isEmpty {
                EmptyPanel(symbol: "person.crop.circle", title: "No contacts cached", subtitle: "Allow Carrier SMS and contacts on Android, grant this Mac access, then refresh.")
            } else {
                List(visibleContacts) { contact in
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(AppTheme.teal)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(contact.name).font(.headline).streamSensitive()
                            Text(contact.phones.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1).streamSensitive()
                        }
                        Spacer()
                        Text(model.phones.first(where: { $0.id == contact.deviceId })?.name ?? "Removed device")
                            .font(.caption).foregroundStyle(.secondary)
                        if let phoneId = contact.deviceId, let number = contact.phones.first {
                            Button("Message", systemImage: "message") {
                                composePhoneId = phoneId; composeAddress = number; showComposer = true
                            }.disabled(!model.connected.contains(phoneId))
                            Button("Call", systemImage: "phone") { model.dial(phoneId: phoneId, number: number) }
                                .disabled(!model.connected.contains(phoneId))
                        }
                    }.padding(.vertical, 5)
                }
            }
            if let phoneId = selectedPhoneId, let status = model.dialStatus[phoneId] {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(28)
        .sheet(isPresented: $showComposer) { SmsComposer(phoneId: $composePhoneId, address: $composeAddress) }
    }
}

struct CallHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPhoneId: String?
    @State private var query = ""
    @State private var dialNumber = ""
    @State private var showComposer = false
    @State private var composeAddress = ""
    @State private var composePhoneId: String?

    private var rows: [CallHistoryRecord] {
        model.callHistory.filter { row in
            row.deviceId == selectedPhoneId &&
            (query.isEmpty || "\(row.name ?? "") \(row.number)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Call History", subtitle: "Recent cellular calls from the selected Android device.")
            BluetoothCallPanel(calls: model.bluetoothCalls)
            HStack(spacing: 12) {
                Picker("Device", selection: $selectedPhoneId) {
                    Text("Choose device").tag(String?.none)
                    ForEach(model.phones) { phone in Text(phone.name).tag(Optional(phone.id)) }
                }.frame(width: 230)
                TextField("Search calls", text: $query).textFieldStyle(.roundedBorder)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    if let selectedPhoneId { model.loadCallHistory(phoneId: selectedPhoneId, reset: true) }
                }.disabled(selectedPhoneId == nil || !model.connected.contains(selectedPhoneId ?? ""))
            }
            HStack(spacing: 10) {
                TextField("Phone number", text: $dialNumber).textFieldStyle(.roundedBorder).streamSensitive()
                Button("Call on phone", systemImage: "phone.fill") {
                    if let selectedPhoneId { model.dial(phoneId: selectedPhoneId, number: dialNumber) }
                }.disabled(selectedPhoneId == nil || !model.connected.contains(selectedPhoneId ?? "") || dialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let selectedPhoneId, let status = model.callHistoryStatus[selectedPhoneId], !rows.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let selectedPhoneId, let status = model.dialStatus[selectedPhoneId] {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if selectedPhoneId == nil {
                EmptyPanel(symbol: "phone", title: "Choose an Android device", subtitle: "Select a phone to browse its call history and dial from your Mac.")
            } else if rows.isEmpty && model.callHistoryLoading {
                ProgressView("Loading call history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty && !model.callHistoryLoading {
                EmptyPanel(symbol: "clock.arrow.circlepath", title: "No calls loaded", subtitle: model.callHistoryStatus[selectedPhoneId ?? ""] ?? "Allow Call history on Android, then refresh while the phone is connected.")
            } else {
                List(rows) { row in
                    HStack(spacing: 14) {
                        Image(systemName: symbol(for: row.type)).foregroundStyle(row.type == 3 ? Color.red : AppTheme.teal)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name?.isEmpty == false ? row.name! : row.number).font(.headline).streamSensitive()
                            if row.name?.isEmpty == false { Text(row.number).font(.caption).foregroundStyle(.secondary).streamSensitive() }
                            Text("\(label(for: row.type)) · \(Date(timeIntervalSince1970: Double(row.timestamp) / 1000).formatted(date: .abbreviated, time: .shortened)) · \(row.duration)s")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let phoneId = row.deviceId, !row.number.isEmpty {
                            Button("Message", systemImage: "message") {
                                composePhoneId = phoneId; composeAddress = row.number; showComposer = true
                            }.disabled(!model.connected.contains(phoneId))
                            Button("Call", systemImage: "phone") { model.dial(phoneId: phoneId, number: row.number) }
                                .disabled(!model.connected.contains(phoneId))
                        }
                    }
                    .padding(.vertical, 5)
                    .onAppear {
                        if row.id == rows.last?.id, let selectedPhoneId, model.callHistoryHasMore[selectedPhoneId] != false {
                            model.loadCallHistory(phoneId: selectedPhoneId)
                        }
                    }
                }
            }
        }.padding(28)
        .sheet(isPresented: $showComposer) { SmsComposer(phoneId: $composePhoneId, address: $composeAddress) }
        .onAppear {
            if selectedPhoneId == nil { selectedPhoneId = model.phones.first(where: { model.connected.contains($0.id) })?.id ?? model.phones.first?.id }
            if let selectedPhoneId, model.callHistory.filter({ $0.deviceId == selectedPhoneId }).isEmpty { model.loadCallHistory(phoneId: selectedPhoneId) }
        }
        .onChange(of: selectedPhoneId) { _, phoneId in
            if let phoneId, model.callHistory.filter({ $0.deviceId == phoneId }).isEmpty { model.loadCallHistory(phoneId: phoneId) }
        }
    }

    private func symbol(for type: Int) -> String {
        switch type { case 1: "phone.arrow.down.left"; case 2: "phone.arrow.up.right"; case 3: "phone.down"; default: "phone" }
    }
    private func label(for type: Int) -> String {
        switch type { case 1: "Incoming"; case 2: "Outgoing"; case 3: "Missed"; case 5: "Rejected"; case 6: "Blocked"; default: "Call" }
    }
}

private struct BluetoothCallPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var calls: BluetoothCalls
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Android device", selection: $calls.selectedPhoneId) {
                        Text("Choose device").tag(String?.none)
                        ForEach(model.phones) { phone in Text(phone.name).tag(Optional(phone.id)) }
                    }.frame(width: 225)
                    Picker("Bluetooth phone", selection: $calls.selectedAddress) {
                        Text("Choose paired phone").tag(String?.none)
                        ForEach(calls.pairedDevices) { device in
                            Text(device.name + (device.advertisesHandsFree ? " · Hands-free" : "")).tag(Optional(device.id))
                        }
                    }.frame(width: 280)
                    Spacer(minLength: 0)
                    Button("Refresh", systemImage: "arrow.clockwise") { calls.refreshPairedDevices() }
                    Button("Pair phone…", systemImage: "antenna.radiowaves.left.and.right") { calls.openBluetoothSettings() }
                }
                HStack(spacing: 8) {
                    if calls.isConnected {
                        Button("Disconnect", systemImage: "xmark.circle") { calls.disconnect() }
                    } else {
                        Button("Connect", systemImage: "waveform.path") { calls.connect() }
                            .disabled(calls.selectedAddress == nil || calls.selectedPhoneId == nil)
                    }
                    Button("Answer call", systemImage: "phone.fill") { calls.answerOnMac() }
                        .disabled(!calls.canAnswer)
                    Button("End call", systemImage: "phone.down.fill", role: .destructive) { calls.endCall() }
                        .disabled(!calls.canEnd)
                    Spacer(minLength: 0)
                    Circle().fill(calls.isConnected ? AppTheme.blue : Color.secondary)
                        .frame(width: 8, height: 8)
                }
                Text(calls.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("Only the selected Mac should connect to Bluetooth calling. Call audio stays on the phone.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 10)
        } label: {
            Label("Bluetooth calling", systemImage: "waveform.path")
                .font(.headline)
        }
        .padding(14)
        .appCard()
        .onAppear { calls.refreshPairedDevices() }
    }
}

struct SmsComposer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Binding var phoneId: String?
    @Binding var address: String
    @State private var bodyText = ""
    @State private var commandId: String?
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("New carrier SMS").font(.title2.bold())
            Picker("Send through",selection: $phoneId) { ForEach(model.phones.filter { model.connected.contains($0.id) }) { phone in Text(phone.name).tag(Optional(phone.id)) } }.frame(maxWidth: .infinity)
            TextField("Phone number",text: $address).textFieldStyle(.roundedBorder).streamSensitive()
            TextField("Message",text: $bodyText,axis: .vertical).lineLimit(4...10).textFieldStyle(.roundedBorder).streamSensitive()
            if let commandId, let state = model.smsCommandStates[commandId] { Text(model.smsCommandDetails[commandId] ?? state).foregroundStyle(state == "accepted" ? AppTheme.teal : state == "failed" ? .red : .orange) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Send",systemImage: "paperplane.fill") { if let phoneId { commandId = model.sendSMS(phoneId: phoneId,address: address,body: bodyText) } }.buttonStyle(.borderedProminent).disabled(phoneId == nil || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            Text("Accepted means Android accepted the carrier SMS request. It does not confirm carrier delivery. Uncertain sends are never retried automatically.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 480)
    }
}
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var now = Date()
    let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var qr: NSImage? {
        guard !model.invitation.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(model.invitation.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SectionHeading(title: "Devices", subtitle: "Pair once. Reconnect when your devices are nearby.")
            HStack(alignment: .top, spacing: 24) {
                if let qr, now < model.invitationExpires { Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16)).streamSensitive(strongBlur: true) }
                else { Image(systemName: "qrcode").font(.system(size: 90)).foregroundStyle(AppTheme.teal).frame(width: 252, height: 252).appCard() }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Connect your Android").font(.title2.bold())
                    Text("Open Android Sync on your phone and scan this invitation. Keep both devices on the same local network.").foregroundStyle(.secondary)
                    if now < model.invitationExpires { Text("Expires in \(max(0, Int(model.invitationExpires.timeIntervalSince(now)))) seconds").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Button("New pairing invitation") { model.newInvitation() }.buttonStyle(.borderedProminent)
                    Button("Copy invitation for manual pairing") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.invitation, forType: .string); NSPasteboard.general.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }.disabled(model.invitation.isEmpty)
                    Text("Local addresses: \(LocalServer.localAddresses().joined(separator: ", "))\nPort: \(model.port)").font(.caption).textSelection(.enabled).foregroundStyle(.secondary).streamSensitive()
                    Text("Pairing code for this Mac: \(model.macId.suffix(6))").font(.caption.monospaced().weight(.semibold)).textSelection(.enabled).foregroundStyle(.secondary).streamSensitive()
                }.padding(.top, 12)
            }
            Text("Trusted phones").font(.headline)
            if model.phones.isEmpty { Text("No devices paired yet.").foregroundStyle(.secondary) }
            ForEach(model.phones) { phone in
                VStack(alignment: .leading,spacing: 10) {
                    HStack { Label(phone.name, systemImage: "iphone").streamSensitive(); Spacer(); Text(model.connected.contains(phone.id) ? "Connected" : "Offline").foregroundStyle(model.connected.contains(phone.id) ? AppTheme.teal : .secondary); Button("Forget", role: .destructive) { model.revoke(phone) } }
                    if let status = model.phoneStatuses[phone.id] {
                        if status.messagesAccess == true && status.messagesPermissions == false {
                            Label("Messages enabled for this Mac; allow SMS and Contacts in Android Settings.", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.secondary).font(.caption)
                        } else if status.messagesAccess == true {
                            Label("Messages access enabled on Android", systemImage: "checkmark.circle.fill").foregroundStyle(AppTheme.teal).font(.caption)
                        } else if status.messagesAccess == false {
                            Label(status.messagesPermissions == false ? "Allow SMS and Contacts in Android Settings, then enable Messages for this Mac in Devices." : "Enable Messages for this Mac in Android Sync → Devices.", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    Toggle("Ask before receiving file batches",isOn: Binding(get: { model.askEveryTimeFiles.contains(phone.id) },set: { model.setAskEveryTimeFiles(phone.id,$0) }))
                    Text(model.askEveryTimeFiles.contains(phone.id) ? "Incoming batches wait for your approval." : "This trusted phone may send batches automatically.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).appCard()
            }
            Text("Pair your other Mac separately. The phone can synchronize with both at the same time.").foregroundStyle(.secondary)
        }.padding(28) }.onReceive(ticker) { now = $0 }
    }
}
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue
    @AppStorage("streamModeEnabled") private var streamModeEnabled = false
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeading(title: "Settings", subtitle: "Make the connection fit your day.")
            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Appearance", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { appearance in Text(appearance.rawValue).tag(appearance.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 16) {
                        Label("Primary actions", systemImage: "circle.fill").foregroundStyle(AppTheme.blue)
                        Label("Status & accents", systemImage: "circle.fill").foregroundStyle(AppTheme.teal)
                    }.font(.caption)
                    Text("System follows your Mac. Light and Dark keep Android Sync in the selected appearance.").font(.caption).foregroundStyle(.secondary)
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Everyday use") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Launch Android Sync at login", isOn: $login).onChange(of: login) { _, value in model.setLogin(value) }
                    Text("Mac notification alerts: \(model.alertsStatus)").foregroundStyle(.secondary)
                    HStack { Button("Enable native notification alerts") { model.requestAlerts() }; Button("Notification settings") { model.openNotificationSettings() } }
                    Text("macOS controls alerts, previews, and Focus behavior in System Settings → Notifications.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("File transfers") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Insecure transfer (faster)", isOn: Binding(
                        get: { model.insecureFileTransfer },
                        set: { model.setInsecureFileTransfer($0) }
                    ))
                    Text("Transfers files without encryption over local Wi-Fi. Anyone with access to the network may see them. This switch syncs with connected Android devices; leave it off for encrypted transfers.").font(.caption).foregroundStyle(.secondary)
                    Text("Save newly accepted batches to").font(.subheadline.weight(.semibold))
                    Text(model.receiveFolder.path).font(.callout).textSelection(.enabled).foregroundStyle(.secondary).streamSensitive()
                    HStack { Button("Choose folder…") { model.chooseReceiveFolder() }; Button("Use Downloads") { model.resetReceiveFolder() } }
                    Toggle("Show file completion notifications", isOn: $model.fileAlerts).onChange(of: model.fileAlerts) { _, _ in model.saveFileAlertPreferences() }
                    Toggle("Play a sound with file notifications", isOn: $model.fileSounds).onChange(of: model.fileSounds) { _, _ in model.saveFileAlertPreferences() }
                    Button("Test Mac notification and sound") { model.testMacAlert() }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Privacy") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Blur Sensitive Information (Stream Mode)", isOn: $streamModeEnabled)
                        .onChange(of: streamModeEnabled) { _, enabled in
                            if enabled {
                                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                            }
                        }
                    Text("Blur messages, numbers, clipboard content, photos, file names, and pairing QR codes in public or while recording. Native alerts show only the source app and a hidden-content notice. Hover over one item to reveal it temporarily on this Mac. Turning this on clears earlier Android Sync alerts from Notification Center.").font(.caption).foregroundStyle(.secondary)
                    Label("Paired control connection uses TLS 1.3", systemImage: "lock.shield")
                    Text("Notifications expire after seven days. Clipboard history and image data are encrypted locally and remain available until you clear them. Trusted devices auto-accept file batches unless Ask every time is enabled for that device.").foregroundStyle(.secondary)
                    Button("Clear notification history", role: .destructive) { model.clearHistory() }
                    Button("Export redacted diagnostics…") { model.exportRedactedDiagnostics() }
                    Text("Diagnostics contain versions, counts, and capability states only. They exclude messages, clipboard contents, filenames, paths, device identities, addresses, and credentials.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Excluded apps") { VStack(alignment: .leading, spacing: 10) { if model.excluded.isEmpty { Text("All permitted phone apps can sync.").foregroundStyle(.secondary) }; ForEach(Array(model.excluded).sorted(), id: \.self) { package in HStack { Text(package); Spacer(); Button("Allow") { model.allowApp(package) } } } }.padding(12).frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Call controls") { Text("Active call notifications can expose Answer, Decline, Mute, and Decline with Message controls. Only controls offered by the Android calling app appear. Call audio remains on the phone.").foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
            Text("Android Sync \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Local") · \(model.status)").font(.caption).foregroundStyle(.secondary)
        }
        .tint(AppTheme.blue)
        .groupBoxStyle(AppGroupBoxStyle())
    }
}
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(nsImage: NSImage(named: "AndroidSync")!).resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true); Text("Android Sync").font(.headline); Spacer(); Circle().fill(model.connected.isEmpty ? .gray : AppTheme.teal).frame(width: 8, height: 8) }
            Text(model.onlineName).foregroundStyle(.secondary).streamSensitive()
            Divider()
            Button("Open Android Sync", systemImage: "macwindow") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("File Transfer", systemImage: "arrow.up.arrow.down.circle") { model.requestedSection = "File Transfer"; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button(model.clipboardPaused ? "Resume clipboard" : "Pause clipboard", systemImage: model.clipboardPaused ? "play" : "pause") { model.toggleClipboard() }
            Divider()
            Text("\(model.notifications.filter { $0.active && $0.localDismissed != true }.count) active notifications").font(.caption).foregroundStyle(.secondary)
            Button("Quit") { NSApp.terminate(nil) }
        }.padding(20).frame(width: 300).buttonStyle(.plain).tint(AppTheme.blue)
    }
}
