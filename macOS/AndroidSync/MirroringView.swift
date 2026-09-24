import SwiftUI
import AppKit

struct MirroringView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selectedPhoneId: String?
    @State private var requestControl = true
    @State private var text = ""
    @State private var adbPairEndpoint = ""
    @State private var adbConnectEndpoint = ""
    @State private var adbCode = ""

    private var selectedPhone: TrustedPhone? { model.phones.first { $0.id == selectedPhoneId } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 18) {
                SectionHeading(title: "Mirror Devices",subtitle: "Share and control an Android screen over the authenticated local realtime connection.")
                HStack {
                    Picker("Android device",selection: $selectedPhoneId) {
                        Text("Choose a device").tag(String?.none)
                        ForEach(model.phones.filter { model.connected.contains($0.id) }) { phone in Text(phone.name).tag(Optional(phone.id)) }
                    }.frame(width: 280)
                    Toggle("Request remote control",isOn: $requestControl).toggleStyle(.checkbox)
                    Spacer()
                    if model.mirrorSessionId == nil {
                        Button("Start mirroring",systemImage: "play.rectangle") {
                            guard let selectedPhoneId else { return }
                            model.startMirroring(phoneId: selectedPhoneId,control: requestControl)
                            if model.mirrorSessionId != nil { openWindow(id: "mirror-screen") }
                        }.buttonStyle(.borderedProminent).disabled(selectedPhoneId == nil)
                    } else {
                        Button("Show screen",systemImage: "macwindow.on.rectangle") { openWindow(id: "mirror-screen") }.buttonStyle(.borderedProminent)
                        Button("Stop",systemImage: "stop.fill",role: .destructive) { model.stopMirroring(); dismissWindow(id: "mirror-screen") }
                    }
                }
                Label(model.mirrorStatus,systemImage: model.mirrorFrame == nil ? "hourglass" : "checkmark.circle.fill").foregroundStyle(model.mirrorFrame == nil ? Color.secondary : AppTheme.teal)
                GroupBox("Screen viewer") {
                    HStack(spacing: 14) {
                        Image(systemName: model.mirrorSessionId == nil ? "rectangle.dashed" : "rectangle.inset.filled")
                            .font(.title2).foregroundStyle(model.mirrorSessionId == nil ? Color.secondary : AppTheme.teal)
                        VStack(alignment: .leading,spacing: 4) {
                            Text(model.mirrorSessionId == nil ? "No active screen" : "Android screen is open in a separate window").font(.headline)
                            Text("This control page stays here while the viewer follows the phone's portrait or landscape orientation.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.mirrorSessionId != nil { Button("Open screen",systemImage: "arrow.up.forward.app") { openWindow(id: "mirror-screen") } }
                    }.padding(12)
                }
                bitrate
                mediaControls
                advancedADB
            }.padding(28)
        }.onAppear { if selectedPhoneId == nil { selectedPhoneId = model.connected.sorted().first }; model.refreshMedia(phoneId: selectedPhoneId) }
        .onChange(of: selectedPhoneId) { _, id in model.refreshMedia(phoneId: id) }
    }

    private var remoteControls: some View {
        GroupBox("Remote control") {
            VStack(alignment: .leading,spacing: 12) {
                HStack {
                    Button("Back",systemImage: "chevron.backward") { model.remoteNavigation("back") }
                    Button("Home",systemImage: "house") { model.remoteNavigation("home") }
                    Button("Recents",systemImage: "rectangle.stack") { model.remoteNavigation("recents") }
                    Button("Notifications",systemImage: "bell") { model.remoteNavigation("notifications") }
                }
                HStack {
                    TextField("Insert text into the focused Android field",text: $text).textFieldStyle(.roundedBorder).streamSensitive()
                    Button("Insert") { model.remoteText(text); text = "" }.disabled(text.isEmpty)
                    Button("Paste Mac clipboard") { if let value = NSPasteboard.general.string(forType: .string) { model.remoteText(value,paste: true) } }
                }
                Text("Secure fields and protected Android surfaces remain unavailable. Text insertion requires an editable field to be focused on Android.").font(.caption).foregroundStyle(.secondary)
                if let status = model.remoteControlStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.padding(12).frame(maxWidth: .infinity,alignment: .leading)
        }
    }

    private var bitrate: some View {
        GroupBox("Stream quality") {
            VStack(alignment: .leading,spacing: 7) {
                HStack {
                    Text("Target bitrate")
                    Slider(value: Binding(get: { Double(model.mirrorBitrate) },set: { model.configureMirrorBitrate(Int($0)) }),in: 1_000_000...12_000_000,step: 500_000)
                    Text(String(format: "%.1f Mbps",Double(model.mirrorBitrate) / 1_000_000)).monospacedDigit().frame(width: 80,alignment: .trailing)
                }
                if let applied = model.mirrorAppliedBitrate {
                    Text(String(format: "Android encoder: %.1f Mbps",Double(applied) / 1_000_000)).font(.caption).foregroundStyle(applied < model.mirrorBitrate ? Color.orange : Color.secondary)
                } else if model.mirrorSessionId != nil {
                    Text("Waiting for the Android encoder…").font(.caption).foregroundStyle(.secondary)
                }
                Text("Android Sync drops stale queued frames and may temporarily reduce the applied bitrate when Wi-Fi cannot keep up.").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }

    @ViewBuilder private var mediaControls: some View {
        if let phoneId = selectedPhoneId, let media = model.mediaStates[phoneId] {
            GroupBox("Android media") {
                HStack(spacing: 14) {
                    Image(systemName: "music.note").font(.title2).foregroundStyle(AppTheme.teal)
                    VStack(alignment: .leading) { Text(media.title.isEmpty ? media.app : media.title).font(.headline).streamSensitive(); Text(media.artist.isEmpty ? media.app : media.artist).foregroundStyle(.secondary).streamSensitive() }
                    Spacer()
                    Button(action: { model.sendMediaCommand(phoneId: phoneId,action: "previous") }) { Image(systemName: "backward.fill") }.disabled(!media.actions.contains("previous"))
                    Button(action: { model.sendMediaCommand(phoneId: phoneId,action: media.playing ? "pause" : "play") }) { Image(systemName: media.playing ? "pause.fill" : "play.fill") }.disabled(!media.actions.contains(media.playing ? "pause" : "play"))
                    Button(action: { model.sendMediaCommand(phoneId: phoneId,action: "next") }) { Image(systemName: "forward.fill") }.disabled(!media.actions.contains("next"))
                }.padding(12)
            }
        }
    }

    private var advancedADB: some View {
        GroupBox("Advanced Mirroring · optional Wireless Debugging") {
            VStack(alignment: .leading,spacing: 12) {
                Text("Android Studio is not required. Android still requires Developer options → Wireless debugging and its pairing flow. Android Sync exposes only pairing and connection operations; it does not provide a remote shell.").foregroundStyle(.secondary)
                HStack { TextField("Pairing address, for example 192.168.1.20:37123",text: $adbPairEndpoint).textFieldStyle(.roundedBorder).streamSensitive(); SecureField("6-digit code",text: $adbCode).textFieldStyle(.roundedBorder).frame(width: 120); Button("Pair") { model.adbPair(endpoint: adbPairEndpoint,code: adbCode) }.disabled(!model.adbAvailable) }
                HStack { TextField("Debug address, for example 192.168.1.20:41817",text: $adbConnectEndpoint).textFieldStyle(.roundedBorder).streamSensitive(); Button("Connect") { model.adbConnect(endpoint: adbConnectEndpoint) }.disabled(!model.adbAvailable); Button("Disconnect") { model.adbDisconnect(endpoint: adbConnectEndpoint) }.disabled(!model.adbAvailable) }
                Text(model.adbAvailable ? model.adbStatus : "The bundled universal ADB executable is missing from this build.").font(.caption).foregroundStyle(model.adbAvailable ? Color.secondary : Color.orange)
            }.padding(12).frame(maxWidth: .infinity,alignment: .leading)
        }
    }
}

struct MirrorScreenWindow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var text = ""
    @State private var showingTextEntry = false

    var body: some View {
        VStack(spacing: 0) {
            MirrorSurface()
                .environmentObject(model)
                .frame(maxWidth: .infinity,maxHeight: .infinity)
                .streamSensitive(strongBlur: true)
                .padding(6)
            Divider()
            HStack(spacing: 4) {
                controlButton("Back",symbol: "chevron.backward") { model.remoteNavigation("back") }
                controlButton("Home",symbol: "house.fill") { model.remoteNavigation("home") }
                controlButton("Recents",symbol: "rectangle.stack.fill") { model.remoteNavigation("recents") }
                controlButton("Alerts",symbol: "bell.fill") { model.remoteNavigation("notifications") }
                Button { showingTextEntry.toggle() } label: {
                    MirrorControlLabel(title: "Type",symbol: "keyboard")
                }
                .buttonStyle(.plain)
                .disabled(!model.mirrorControlEnabled)
                .popover(isPresented: $showingTextEntry,arrowEdge: .bottom) {
                    VStack(alignment: .leading,spacing: 10) {
                        Text("Type on Android").font(.headline)
                        HStack {
                            TextField("Text",text: $text).textFieldStyle(.roundedBorder).frame(minWidth: 260).onSubmit(sendText).streamSensitive()
                            Button("Insert",action: sendText).buttonStyle(.borderedProminent).disabled(text.isEmpty)
                        }
                        Button("Paste Mac clipboard",systemImage: "doc.on.clipboard") {
                            if let value = NSPasteboard.general.string(forType: .string) { model.remoteText(value,paste: true) }
                            showingTextEntry = false
                        }
                    }.padding(16)
                }
                Button(role: .destructive) {
                    model.stopMirroring()
                    dismissWindow(id: "mirror-screen")
                } label: {
                    MirrorControlLabel(title: "Stop",symbol: "stop.fill",tint: .red)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal,8).padding(.vertical,7)
            .background(.bar)
        }
        .background(Color.black)
        .background(MirrorWindowSizer(width: model.mirrorWidth,height: model.mirrorHeight))
        .onChange(of: model.mirrorSessionId) { _, sessionId in if sessionId == nil { dismissWindow(id: "mirror-screen") } }
        .onDisappear { if model.mirrorSessionId != nil { model.stopMirroring() } }
    }

    private func controlButton(_ title: String,symbol: String,action: @escaping () -> Void) -> some View {
        Button(action: action) { MirrorControlLabel(title: title,symbol: symbol) }
            .buttonStyle(.plain)
            .disabled(!model.mirrorControlEnabled)
    }

    private func sendText() {
        guard !text.isEmpty else { return }
        model.remoteText(text); text = ""; showingTextEntry = false
    }
}

private struct MirrorControlLabel: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 15,weight: .semibold)).frame(height: 18)
            Text(title).font(.system(size: 10,weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity,minHeight: 48)
        .contentShape(Rectangle())
    }
}

private struct MirrorWindowSizer: NSViewRepresentable {
    let width: Int
    let height: Int

    final class Coordinator {
        var lastSize: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView,context: Context) {
        let sourceWidth = width > 0 ? width : 1080
        let sourceHeight = height > 0 ? height : 2400
        let key = "\(sourceWidth)x\(sourceHeight)"
        DispatchQueue.main.async {
            guard context.coordinator.lastSize != key,let window = view.window,let screen = window.screen ?? NSScreen.main else { return }
            context.coordinator.lastSize = key
            let visible = screen.visibleFrame
            window.level = .floating
            let aspect = CGFloat(sourceWidth) / CGFloat(sourceHeight)
            let controlsHeight: CGFloat = 64
            let maxScreenWidth = min(980,visible.width * 0.72)
            let maxScreenHeight = min(760,visible.height * 0.78)
            var screenWidth: CGFloat
            var screenHeight: CGFloat
            if aspect >= 1 {
                screenWidth = maxScreenWidth
                screenHeight = screenWidth / aspect
            } else {
                screenHeight = maxScreenHeight
                screenWidth = screenHeight * aspect
                if screenWidth < 310 {
                    screenWidth = 310
                    screenHeight = screenWidth / aspect
                }
                if screenHeight > maxScreenHeight {
                    screenHeight = maxScreenHeight
                    screenWidth = screenHeight * aspect
                }
            }
            let contentSize = NSSize(width: max(310,screenWidth),height: max(360,screenHeight + controlsHeight))
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero,size: contentSize)).size
            var origin = NSPoint(x: window.frame.minX,y: window.frame.maxY - frameSize.height)
            origin.x = min(max(origin.x,visible.minX),visible.maxX - frameSize.width)
            origin.y = min(max(origin.y,visible.minY),visible.maxY - frameSize.height)
            window.setFrame(NSRect(origin: origin,size: frameSize),display: true,animate: true)
        }
    }
}

private struct MirrorSurface: View {
    @EnvironmentObject var model: AppModel
    @State private var dragStart: CGPoint?
    var body: some View {
        GeometryReader { proxy in
            let content = fittedRect(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.black)
                if let frame = model.mirrorFrame {
                    Image(nsImage: frame).resizable().interpolation(.none).scaledToFit().frame(width: content.width,height: content.height).position(x: content.midX,y: content.midY)
                } else {
                    ContentUnavailableView("Waiting for Android",systemImage: "rectangle.dashed.and.paperclip",description: Text("After you start, tap the Android notification and approve the fresh system capture dialog."))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0,coordinateSpace: .local).onChanged { value in if dragStart == nil { dragStart = value.startLocation } }.onEnded { value in
                    defer { dragStart = nil }; guard model.mirrorControlEnabled, content.contains(value.startLocation), content.contains(value.location) else { return }
                    let start = normalized(value.startLocation,in: content); let end = normalized(value.location,in: content)
                    if hypot(value.translation.width,value.translation.height) < 6 { model.remoteTap(x: start.x,y: start.y) }
                    else { model.remoteSwipe(x: start.x,y: start.y,endX: end.x,endY: end.y) }
                })
        }
    }
    private func fittedRect(in available: CGSize) -> CGRect {
        let width = Double(model.mirrorWidth > 0 ? model.mirrorWidth : 9); let height = Double(model.mirrorHeight > 0 ? model.mirrorHeight : 16)
        let scale = min(available.width / width,available.height / height); let size = CGSize(width: width * scale,height: height * scale)
        return CGRect(x: (available.width-size.width)/2,y: (available.height-size.height)/2,width: size.width,height: size.height)
    }
    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint { CGPoint(x: min(max((point.x-rect.minX)/rect.width,0),1),y: min(max((point.y-rect.minY)/rect.height,0),1)) }
}
