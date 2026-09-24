import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileSharingView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: [URL] = []
    @State private var direction = "All"
    @State private var selectedPhoneId: String?
    @State private var remoteSelection: Set<String> = []
    var records: [TransferRecord] { model.transfers.filter { direction == "All" || (direction == "Received" ? $0.incoming : !$0.incoming) } }
    var connectedPhones: [TrustedPhone] { model.phones.filter { model.connected.contains($0.id) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: "File sharing", subtitle: "Choose a batch, send it, and follow every transfer.")
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Send to your phone", systemImage: "arrow.up.doc").font(.headline)
                            Spacer()
                            Button("Choose files…") { chooseFiles() }.disabled(model.preparingFiles)
                        }
                        if connectedPhones.count > 1 {
                            Picker("Android device",selection: Binding(get: { selectedPhoneId ?? connectedPhones.first?.id },set: { selectedPhoneId = $0 })) {
                                ForEach(connectedPhones) { phone in Text(phone.name).tag(Optional(phone.id)) }
                            }.frame(maxWidth: 300)
                        }
                        if selection.isEmpty {
                            Text("Select multiple files or drop them here to build a batch.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 72)
                        } else {
                            ForEach(selection, id: \.self) { url in
                                HStack {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                    Text(url.lastPathComponent).lineLimit(1).streamSensitive()
                                    Spacer()
                                    Button { selection.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Remove from batch")
                                }
                            }
                            HStack {
                                Text("\(selection.count) \(selection.count == 1 ? "file" : "files") selected").foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear batch") { selection.removeAll() }
                                Button("Send batch", systemImage: "paperplane") { model.offerFiles(selection,phoneId: selectedPhoneId ?? connectedPhones.first?.id); selection.removeAll() }.buttonStyle(.borderedProminent).disabled(model.connected.isEmpty || model.preparingFiles)
                            }
                        }
                        if model.preparingFiles { ProgressView("Preparing files and checking integrity…") }
                        if model.connected.isEmpty { Label("Connect your phone to send files.", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
                    }.padding(12)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Android shared storage",systemImage: "externaldrive.connected.to.line.below").font(.headline)
                            Spacer()
                            if let phoneId = selectedPhoneId ?? connectedPhones.first?.id { Button("Browse") { remoteSelection.removeAll(); model.browseStorage(phoneId: phoneId) } }
                        }
                        if model.remoteStorageLoading { ProgressView("Loading Android folder…") }
                        if model.remoteStoragePhoneId != nil {
                            HStack {
                                Button { if let phoneId = model.remoteStoragePhoneId, let parent = model.remoteStorageParent { remoteSelection.removeAll(); model.browseStorage(phoneId: phoneId,path: parent) } } label: { Label("Up",systemImage: "arrow.up") }.disabled(model.remoteStorageParent == nil)
                                Text("/" + model.remoteStoragePath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).streamSensitive()
                                Spacer()
                                Button("Upload here…") { uploadToRemoteFolder() }.disabled(model.remoteStoragePath.isEmpty)
                            }
                            if let message = model.remoteStorageMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                            ForEach(model.remoteStorageEntries) { entry in
                                HStack {
                                    Image(systemName: entry.directory ? "folder.fill" : "doc").foregroundStyle(entry.directory ? AppTheme.teal : Color.secondary)
                                    VStack(alignment: .leading) { Text(entry.name).lineLimit(1).streamSensitive(); if !entry.directory { Text(ByteCountFormatter.string(fromByteCount: entry.size,countStyle: .file)).font(.caption).foregroundStyle(.secondary) } }
                                    Spacer()
                                    if entry.directory { Button("Open") { if let phoneId = model.remoteStoragePhoneId { remoteSelection.removeAll(); model.browseStorage(phoneId: phoneId,path: entry.path) } } }
                                    else { Toggle("Select",isOn: Binding(get: { remoteSelection.contains(entry.path) },set: { selected in if selected { remoteSelection.insert(entry.path) } else { remoteSelection.remove(entry.path) } })).labelsHidden() }
                                }.padding(.vertical,4)
                            }
                            if !remoteSelection.isEmpty { Button("Download \(remoteSelection.count) selected",systemImage: "arrow.down.circle") { model.downloadRemoteFiles(Array(remoteSelection)); remoteSelection.removeAll() }.buttonStyle(.borderedProminent) }
                        } else { Text("Browse user-visible Android storage, then download files or upload into the open folder. Android/data, Android/obb, and app-private data stay excluded.").foregroundStyle(.secondary) }
                    }.padding(12)
                }
                HStack { Label("Receiving folder", systemImage: "folder"); Text(model.receiveFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).streamSensitive(); Spacer(); Button("Change…") { model.chooseReceiveFolder() } }.font(.callout)
                HStack { Text("Transfers").font(.title2.bold()); Spacer(); Picker("Show", selection: $direction) { ForEach(["All", "Sent", "Received"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 240) }
                if records.isEmpty {
                    EmptyPanel(symbol: "folder.badge.plus", title: "Ready to share", subtitle: "Trusted incoming batches start automatically. Enable Ask every time per device when approval is preferred. Completion and failure alerts can play a sound.").frame(minHeight: 200)
                } else { LazyVStack(spacing: 14) { ForEach(records) { FileTransferCard(transfer: $0) } } }
            }.padding(28)
        }.onAppear { if selectedPhoneId == nil { selectedPhoneId = connectedPhones.first?.id } }.onChange(of: model.connected) { _, _ in if selectedPhoneId.map({ !model.connected.contains($0) }) == true { selectedPhoneId = connectedPhones.first?.id } }.onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url, url.isFileURL { urls.append(url) }
                }
                addFiles(urls)
            }
            return true
        }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    private func addFiles(_ urls: [URL]) {
        var batch = selection
        for url in urls where !batch.contains(url) { batch.append(url) }
        guard batch.count <= 100 else { model.error = "Choose up to 100 files in a batch."; return }
        selection = batch
    }
    private func uploadToRemoteFolder() {
        guard let phoneId = model.remoteStoragePhoneId else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.offerFiles(panel.urls,phoneId: phoneId,targetPath: model.remoteStoragePath) }
    }
}

struct FileTransferCard: View {
    @EnvironmentObject var model: AppModel
    let transfer: TransferRecord
    @State private var expanded = false
    private var finished: Bool { ["Completed", "Declined", "Cancelled"].contains(transfer.status) }
    private var progress: Double { transfer.status == "Completed" ? 1 : min(1, max(0, Double(transfer.bytes) / Double(max(1, transfer.total)))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: transfer.incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill").foregroundStyle(AppTheme.teal)
                Text(transfer.offer.files.first?.name ?? "Files").font(.headline).lineLimit(1).streamSensitive()
                if transfer.offer.files.count > 1 { Text("+\(transfer.offer.files.count - 1) more").foregroundStyle(.secondary) }
                Spacer()
                Text(transfer.incoming ? "Received" : "Sent").font(.caption).foregroundStyle(.secondary)
            }
            Text(transfer.status).font(.subheadline).foregroundStyle(transfer.status == "Completed" ? AppTheme.teal : Color.secondary)
            if !finished { AppProgressBar(value: progress) }
            HStack {
                Text("\(Int(progress * 100))% · \(ByteCountFormatter.string(fromByteCount: transfer.status == "Completed" ? transfer.total : transfer.bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))")
                Spacer()
                Text("\(transfer.status == "Completed" ? transfer.offer.files.count : transfer.completed.count)/\(transfer.offer.files.count) files")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if !finished, let speed = transfer.speedBytesPerSecond, speed > 0 { Text("\(ByteCountFormatter.string(fromByteCount: speed,countStyle: .file))/s").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            DisclosureGroup("Files in this batch", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) { ForEach(transfer.offer.files) { file in HStack { Text(file.name).lineLimit(1).streamSensitive(); Spacer(); Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).foregroundStyle(.secondary) } } }.padding(.top, 8)
            }.font(.callout)
            HStack {
                if transfer.incoming && !transfer.accepted && !finished { Button("Accept batch") { model.acceptTransfer(transfer.id) }.buttonStyle(.borderedProminent); Button("Decline") { model.declineTransfer(transfer.id) } }
                if transfer.status.contains("Interrupted") || transfer.status.contains("Failed") { Button("Resume") { model.resumeTransfer(transfer.id) } }
                if !finished { Button("Cancel") { model.cancelTransfer(transfer.id) } }
                if !transfer.savedPaths.isEmpty { Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(transfer.savedPaths.values.map { URL(fileURLWithPath: $0) }) } }
            }
        }.padding(18).appCard()
    }
}

struct NotificationSetupStatus: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.connected.isEmpty {
                ForEach(Array(model.connected).sorted(), id: \.self) { id in
                    if let status = model.phoneStatuses[id] {
                        if !status.notificationAccess { Label("Notification access is off on your phone. Open Android Sync → Setup → Notification access and enable Android Sync.", systemImage: "exclamationmark.bubble").foregroundStyle(.orange) }
                        else if !status.listenerConnected { Label("Android notification access is enabled. Open Android Sync on your phone to reconnect its notification listener.", systemImage: "arrow.clockwise").foregroundStyle(.orange) }
                        else { Label("Phone notification mirroring is active", systemImage: "checkmark.circle.fill").foregroundStyle(AppTheme.teal) }
                    } else { Label("Checking phone permissions. Update the Android app if this persists.", systemImage: "info.circle").foregroundStyle(.secondary) }
                }
            }
            HStack {
                Label("Mac alerts: \(model.alertsStatus)", systemImage: model.alertsAuthorized ? "bell.badge" : "bell.slash").foregroundStyle(.secondary)
                Spacer()
                if !model.alertsAuthorized { Button(model.requestingAlerts ? "Requesting…" : "Enable alerts") { model.requestAlerts() }.disabled(model.requestingAlerts); Button("Mac settings") { model.openNotificationSettings() } }
                Button("Refresh notifications") { model.refreshPhoneNotifications() }.disabled(model.connected.isEmpty)
            }
        }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading).appCard().onAppear { model.refreshAlertSettings() }
    }
}

// MARK: - Paged content browsers

private struct InlineTransferProgress: View {
    let transfer: TransferRecord
    private var finished: Bool { ["Completed", "Declined", "Cancelled"].contains(transfer.status) }
    private var progress: Double { transfer.status == "Completed" ? 1 : min(1,max(0,Double(transfer.bytes) / Double(max(1,transfer.total)))) }
    var body: some View {
        if !finished { AppProgressBar(value: progress) }
        HStack(spacing: 8) {
            Text("\(Int(progress * 100))%")
            Text("·")
            Text("\(transfer.status == "Completed" ? transfer.offer.files.count : transfer.completed.count) of \(transfer.offer.files.count) files")
            Text("·")
            Text("\(ByteCountFormatter.string(fromByteCount: transfer.status == "Completed" ? transfer.total : transfer.bytes,countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: transfer.total,countStyle: .file))")
            if transfer.status != "Completed",let speed = transfer.speedBytesPerSecond,speed > 0 {
                Text("·")
                Text("\(ByteCountFormatter.string(fromByteCount: speed,countStyle: .file))/s")
            }
            Spacer()
            Text(transfer.status)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct FilesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPhoneId: String?
    @State private var selection = Set<String>()
    @State private var dropTargeted = false
    private var connectedPhones: [TrustedPhone] { model.phones.filter { model.connected.contains($0.id) } }
    private var selectedEntries: [StorageEntry] { model.remoteStorageEntries.filter { selection.contains($0.path) } }
    private var storageTransfer: TransferRecord? {
        guard let id = model.remoteStorageTransferId else { return nil }
        return model.transfers.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            HStack(alignment: .firstTextBaseline,spacing: 12) {
                Text("Files").font(.largeTitle.bold())
                Text("Browse shared Android storage in pages of 100 items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Send files…",systemImage: "paperplane") { chooseUpload() }.disabled(selectedPhoneId == nil)
            }
            HStack(spacing: 12) {
                Picker("Android device",selection: $selectedPhoneId) {
                    Text("Choose a connected device").tag(String?.none)
                    ForEach(connectedPhones) { phone in Text(phone.name).tag(Optional(phone.id)) }
                }.frame(width: 300)
                if let phoneId = selectedPhoneId {
                    Label(model.phones.first(where: { $0.id == phoneId })?.name ?? "Android device",systemImage: "iphone")
                        .font(.callout.weight(.semibold))
                    Label(model.connected.contains(phoneId) ? "Connected" : "Offline",systemImage: model.connected.contains(phoneId) ? "wifi" : "wifi.slash")
                        .font(.callout)
                        .foregroundStyle(model.connected.contains(phoneId) ? AppTheme.teal : Color.secondary)
                }
                Spacer()
                Button("Refresh",systemImage: "arrow.clockwise") { reloadFolder() }.disabled(selectedPhoneId == nil || model.remoteStorageLoading)
            }
            fileManagerArea
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            HStack(spacing: 8) {
                Label("Default download folder",systemImage: "folder")
                Text(model.receiveFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).streamSensitive()
                Spacer()
                Button("Change…") { model.chooseReceiveFolder() }
            }.font(.callout)
            VStack(alignment: .leading,spacing: 7) {
                HStack {
                    Text(model.remoteStorageMessage ?? (selection.isEmpty ? "Select files or folders. Double-click a folder to open it." : "\(selectedEntries.count) selected"))
                        .font(.callout).foregroundStyle(storageTransfer?.status == "Completed" ? AppTheme.teal : Color.secondary).lineLimit(1)
                    Spacer()
                    Button("Select all",systemImage: "checkmark.circle") { selectAllLoaded() }
                        .disabled(model.remoteStorageEntries.isEmpty || allLoadedSelected)
                    Button("Deselect",systemImage: "xmark.circle") { selection.removeAll() }
                        .disabled(selection.isEmpty)
                    if !selectedEntries.isEmpty {
                        Button("Download",systemImage: "arrow.down.circle") { model.downloadRemoteFiles(selectedEntries.map(\.path)) }
                        Button("Download to…",systemImage: "folder.badge.plus") { downloadToFolder() }
                    }
                }
                if let transfer = storageTransfer { InlineTransferProgress(transfer: transfer) }
                else if model.remoteStorageMessage?.hasPrefix("Preparing") == true { AppProgressBar() }
            }
        }.padding(20)
        .onAppear { selectInitialDevice() }
        .onChange(of: selectedPhoneId) { _, id in selection.removeAll(); if let id { model.browseStorage(phoneId: id) } }
        .onChange(of: model.connected) { _, _ in if selectedPhoneId.map({ !model.connected.contains($0) }) == true { selectedPhoneId = connectedPhones.first?.id } }
    }

    private var fileManagerArea: some View {
        VStack(spacing: 0) {
            HStack {
                Button { openParent() } label: { Label("Up",systemImage: "chevron.left") }.disabled(model.remoteStorageParent == nil)
                Image(systemName: "externaldrive.fill").foregroundStyle(AppTheme.teal)
                Text(openFolderLabel).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).streamSensitive()
                Spacer()
                Text("\(model.remoteStorageEntries.count) loaded").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            HStack {
                Text("Name").frame(maxWidth: .infinity,alignment: .leading)
                Text("Modified").frame(width: 150,alignment: .leading)
                Text("Type").frame(width: 110,alignment: .leading)
                Text("Size").frame(width: 90,alignment: .trailing)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,8)
            Divider()
            Group {
                if model.remoteStoragePhoneId == nil {
                    EmptyPanel(symbol: "externaldrive",title: "Choose an Android device",subtitle: "Each device opens its own shared-storage browser. Private app folders remain excluded.")
                } else if model.remoteStorageEntries.isEmpty && !model.remoteStorageLoading {
                    EmptyPanel(symbol: "folder",title: "No files here",subtitle: model.remoteStorageMessage ?? "This Android folder is empty.")
                } else {
                    List {
                        ForEach(model.remoteStorageEntries) { entry in
                            let isSelected = selection.contains(entry.path)
                            FileBrowserRow(entry: entry)
                                .listRowBackground(isSelected ? AppTheme.blue.opacity(0.14) : Color.clear)
                                .contentShape(Rectangle())
                                .overlay {
                                    if let phoneId = selectedPhoneId {
                                        let entries = isSelected ? selectedEntries : [entry]
                                        RemoteContentCardDragSource(
                                            model: model,
                                            phoneId: phoneId,
                                            items: entries.map { RemoteDragItem(id: $0.path,name: $0.name,mime: $0.mime,kind: .file,directory: $0.directory) },
                                            onClick: { toggleSelection(entry.path) },
                                            onDoubleClick: entry.directory ? { openFolder(entry.path) } : nil
                                        )
                                        .contentShape(Rectangle())
                                        .help(isSelected && selectedEntries.count > 1 ? "Drag \(selectedEntries.count) selected items to Finder" : "Drag \(entry.name) to Finder")
                                    }
                                }
                                .onAppear { if entry.id == model.remoteStorageEntries.last?.id, model.remoteStorageHasMore { model.loadMoreStorage() } }
                        }
                        if model.remoteStorageLoading { HStack { Spacer(); ProgressView("Loading next 100 files…"); Spacer() }.padding() }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minHeight: 260,maxHeight: .infinity)
        }
        .background(dropTargeted ? AppTheme.blue.opacity(0.12) : AppTheme.card(for: colorScheme),in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(dropTargeted ? AppTheme.blue : Color.primary.opacity(0.10),lineWidth: dropTargeted ? 2.5 : 1)
            if dropTargeted {
                Label("Upload to \(openFolderLabel)",systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .padding(.horizontal,18).padding(.vertical,12)
                    .background(.regularMaterial,in: RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL],isTargeted: $dropTargeted) { providers in
            guard selectedPhoneId != nil else { return false }
            receiveDroppedFiles(providers)
            return true
        }
    }

    private var openFolderLabel: String {
        model.remoteStoragePath.isEmpty ? "Device storage" : "Device storage / \(model.remoteStoragePath)"
    }
    private func selectInitialDevice() { if selectedPhoneId == nil { selectedPhoneId = connectedPhones.first?.id } else if let selectedPhoneId { model.browseStorage(phoneId: selectedPhoneId) } }
    private func reloadFolder() { guard let phoneId = selectedPhoneId else { return }; selection.removeAll(); model.browseStorage(phoneId: phoneId,path: model.remoteStoragePhoneId == phoneId ? model.remoteStoragePath : "") }
    private func openParent() { guard let phoneId = selectedPhoneId, let parent = model.remoteStorageParent else { return }; selection.removeAll(); model.browseStorage(phoneId: phoneId,path: parent) }
    private var allLoadedSelected: Bool {
        let selectable = model.remoteStorageEntries.prefix(100)
        return !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.path) } && selection.count == selectable.count
    }
    private func selectAllLoaded() {
        selection = Set(model.remoteStorageEntries.prefix(100).map(\.path))
        if model.remoteStorageEntries.count > 100 { model.remoteStorageMessage = "Selected the first 100 loaded items, the maximum batch size." }
    }
    private func toggleSelection(_ path: String) {
        if selection.contains(path) { selection.remove(path) } else if selection.count < 100 { selection.insert(path) }
        else { model.remoteStorageMessage = "Choose up to 100 files or folders in one batch." }
    }
    private func openFolder(_ path: String) {
        guard let phoneId = selectedPhoneId else { return }
        selection.removeAll(); model.browseStorage(phoneId: phoneId,path: path)
    }
    private func chooseUpload() {
        guard let phoneId = selectedPhoneId else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.offerFiles(Array(panel.urls.prefix(100)),phoneId: phoneId,targetPath: model.remoteStoragePath) }
    }
    private func receiveDroppedFiles(_ providers: [NSItemProvider]) {
        guard let phoneId = selectedPhoneId else { return }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers.prefix(100) {
                let url: URL? = await withCheckedContinuation { continuation in _ = provider.loadObject(ofClass: URL.self) { value,_ in continuation.resume(returning: value) } }
                if let url, url.isFileURL { urls.append(url) }
            }
            if !urls.isEmpty { model.offerFiles(urls,phoneId: phoneId,targetPath: model.remoteStoragePath) }
        }
    }
    private func downloadToFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let folder = panel.url { model.downloadRemoteFiles(selectedEntries.map(\.path),destinationFolder: folder) }
    }
}

private struct FileBrowserRow: View {
    let entry: StorageEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.directory ? "folder.fill" : icon).foregroundStyle(entry.directory ? AppTheme.teal : Color.secondary).frame(width: 20)
            Text(entry.name).lineLimit(1).frame(maxWidth: .infinity,alignment: .leading).streamSensitive()
            Text(Date(timeIntervalSince1970: Double(entry.modified) / 1000),format: .dateTime.month(.abbreviated).day().year()).frame(width: 150,alignment: .leading).foregroundStyle(.secondary)
            Text(entry.directory ? "Folder" : entry.mime).lineLimit(1).frame(width: 110,alignment: .leading).foregroundStyle(.secondary)
            Text(entry.directory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size,countStyle: .file)).frame(width: 90,alignment: .trailing).foregroundStyle(.secondary)
        }.padding(.vertical,5)
    }
    private var icon: String { entry.mime.hasPrefix("image/") ? "photo" : entry.mime.hasPrefix("video/") ? "film" : entry.mime.hasPrefix("audio/") ? "waveform" : "doc" }
}

struct PhotosView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedPhoneId: String?
    @State private var selection = Set<String>()
    @State private var filter = "All"
    @State private var layout = "Grid"
    @State private var previewEntry: MediaEntry?
    private var connectedPhones: [TrustedPhone] { model.phones.filter { model.connected.contains($0.id) } }
    private var displayed: [MediaEntry] { model.galleryEntries.filter { filter == "All" || (filter == "Videos" ? $0.isVideo : !$0.isVideo) } }
    private var selectedItems: [MediaEntry] { model.galleryEntries.filter { selection.contains($0.id) } }
    private var galleryTransfer: TransferRecord? {
        guard let id = model.galleryTransferId else { return nil }
        return model.transfers.first { $0.id == id }
    }
    private let columns = [GridItem(.adaptive(minimum: 150,maximum: 220),spacing: 12)]

    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack(alignment: .top) {
                SectionHeading(title: "Photos & Videos",subtitle: "Browse 20 items at a time, select a batch, and download it anywhere.")
                Spacer()
                Picker("Show",selection: $filter) { ForEach(["All","Photos","Videos"],id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 240)
            }
            HStack {
                Picker("Android device",selection: $selectedPhoneId) {
                    Text("Choose a connected device").tag(String?.none)
                    ForEach(connectedPhones) { phone in Text(phone.name).tag(Optional(phone.id)) }
                }.frame(width: 280)
                Spacer()
                Text("\(model.galleryEntries.count) loaded").font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Layout",selection: $layout) {
                    Label("Grid",systemImage: "square.grid.2x2").labelStyle(.iconOnly).tag("Grid")
                    Label("List",systemImage: "list.bullet").labelStyle(.iconOnly).tag("List")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 76)
                Button("Refresh",systemImage: "arrow.clockwise") { if let selectedPhoneId { selection.removeAll(); model.browseGallery(phoneId: selectedPhoneId) } }.disabled(selectedPhoneId == nil || model.galleryLoading)
            }
            if model.galleryPhoneId == nil {
                EmptyPanel(symbol: "photo.stack",title: "Choose an Android device",subtitle: "Photos and videos stay on the phone until you download the selected items.")
            } else if displayed.isEmpty && !model.galleryLoading {
                EmptyPanel(symbol: "photo",title: "No media found",subtitle: model.galleryMessage ?? "This device has no matching photos or videos.")
            } else {
                ScrollView {
                    if layout == "Grid" {
                        LazyVGrid(columns: columns,spacing: 12) {
                            ForEach(displayed) { entry in
                                let isSelected = selection.contains(entry.id)
                                Button { toggleSelection(entry.id) } label: {
                                    MediaCard(entry: entry,selected: isSelected)
                                        .environmentObject(model)
                                }
                                    .buttonStyle(.plain)
                                    .contentShape(RoundedRectangle(cornerRadius: 14))
                                    .accessibilityLabel("\(entry.name), \(isSelected ? "selected" : "not selected")")
                                    .accessibilityAction(named: "Preview") { previewEntry = entry }
                                    .overlay {
                                        if let phoneId = selectedPhoneId {
                                            let entries = isSelected ? selectedItems : [entry]
                                            RemoteContentCardDragSource(
                                                model: model,
                                                phoneId: phoneId,
                                                items: entries.map { RemoteDragItem(id: $0.id,name: $0.name,mime: $0.mime,kind: .gallery) },
                                                onClick: { toggleSelection(entry.id) },
                                                onDoubleClick: { previewEntry = entry }
                                            )
                                            .contentShape(RoundedRectangle(cornerRadius: 14))
                                            .help(isSelected && selectedItems.count > 1 ? "Drag \(selectedItems.count) selected items to Finder" : "Double-click to preview · Drag \(entry.name) to Finder")
                                        }
                                    }
                                    .overlay(alignment: .topLeading) {
                                        Button { previewEntry = entry } label: {
                                            Image(systemName: "eye.fill")
                                                .foregroundStyle(.white)
                                                .padding(7)
                                                .background(.black.opacity(0.68),in: Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(10)
                                        .help("Preview \(entry.name)")
                                    }
                                    .onAppear { prepare(entry) }
                            }
                        }.padding(.vertical,4)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(displayed) { entry in
                                let isSelected = selection.contains(entry.id)
                                MediaListRow(entry: entry,selected: isSelected)
                                .environmentObject(model)
                                .overlay {
                                    if let phoneId = selectedPhoneId {
                                        let entries = isSelected ? selectedItems : [entry]
                                        RemoteContentCardDragSource(
                                            model: model,
                                            phoneId: phoneId,
                                            items: entries.map { RemoteDragItem(id: $0.id,name: $0.name,mime: $0.mime,kind: .gallery) },
                                            onClick: { toggleSelection(entry.id) },
                                            onDoubleClick: { previewEntry = entry }
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 14))
                                        .help(isSelected && selectedItems.count > 1 ? "Drag \(selectedItems.count) selected items to Finder" : "Double-click to preview · Drag \(entry.name) to Finder")
                                    }
                                }
                                .overlay(alignment: .trailing) {
                                    Button("Preview",systemImage: "eye") { previewEntry = entry }
                                        .labelStyle(.iconOnly)
                                        .padding(.trailing,9)
                                        .help("Preview \(entry.name)")
                                }
                                .accessibilityAction(named: "Preview") { previewEntry = entry }
                                .onAppear { prepare(entry) }
                            }
                        }
                        .padding(.vertical,4)
                    }
                    if model.galleryLoading { ProgressView("Loading next 20 items…").padding(24) }
                }
            }
            VStack(alignment: .leading,spacing: 7) {
                HStack {
                    Text(model.galleryMessage ?? (selection.isEmpty ? "Select photos or videos to download." : "\(selectedItems.count) selected"))
                        .font(.callout).foregroundStyle(galleryTransfer?.status == "Completed" ? AppTheme.teal : Color.secondary).lineLimit(1)
                    Spacer()
                    Button("Select all",systemImage: "checkmark.circle") { selectAllDisplayed() }
                        .disabled(displayed.isEmpty || allDisplayedSelected)
                    Button("Deselect",systemImage: "xmark.circle") { selection.removeAll() }
                        .disabled(selection.isEmpty)
                    if !selectedItems.isEmpty {
                        if selectedItems.count == 1, let entry = selectedItems.first {
                            Button("Preview",systemImage: "eye") { previewEntry = entry }
                        }
                        Button("Download",systemImage: "arrow.down.circle") { model.downloadGallery(selectedItems.map(\.id)) }
                        Button("Download to…",systemImage: "folder.badge.plus") { downloadToFolder() }
                    }
                }
                if let transfer = galleryTransfer {
                    InlineTransferProgress(transfer: transfer)
                } else if model.galleryMessage?.hasPrefix("Preparing") == true {
                    AppProgressBar()
                }
            }
        }.padding(28)
        .sheet(item: $previewEntry) { entry in MediaPreviewSheet(entry: entry).environmentObject(model) }
        .onAppear { if selectedPhoneId == nil { selectedPhoneId = connectedPhones.first?.id } }
        .onChange(of: selectedPhoneId) { _, id in selection.removeAll(); if let id { model.browseGallery(phoneId: id) } }
        .onChange(of: model.connected) { _, _ in if selectedPhoneId.map({ !model.connected.contains($0) }) == true { selectedPhoneId = connectedPhones.first?.id } }
    }
    private var allDisplayedSelected: Bool {
        let selectable = displayed.prefix(100)
        return !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.id) } && selection.count == selectable.count
    }
    private func selectAllDisplayed() {
        selection = Set(displayed.prefix(100).map(\.id))
        if displayed.count > 100 { model.galleryMessage = "Selected the first 100 visible items, the maximum batch size." }
    }
    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) }
        else { selection.insert(id) }
    }
    private func prepare(_ entry: MediaEntry) {
        model.requestGalleryThumbnail(entry)
        if entry.id == displayed.last?.id, model.galleryHasMore { model.loadMoreGallery() }
    }
    private func downloadToFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let folder = panel.url { model.downloadGallery(selectedItems.map(\.id),destinationFolder: folder) }
    }
}

private struct MediaListRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var model: AppModel
    let entry: MediaEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 9).fill(.quaternary)
                if let image = model.galleryThumbnail(for: entry) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: entry.isVideo ? "film" : "photo").foregroundStyle(.secondary)
                }
                if entry.isVideo { Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).padding(5).background(.black.opacity(0.7),in: Circle()).padding(4) }
            }
            .frame(width: 58,height: 48)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .streamSensitive(strongBlur: true)

            VStack(alignment: .leading,spacing: 5) {
                Text(entry.name).font(.callout.weight(.semibold)).lineLimit(1).streamSensitive()
                HStack(spacing: 10) {
                    Label(entry.isVideo ? "Video" : "Photo",systemImage: entry.isVideo ? "film" : "photo")
                    Text("\(entry.width)×\(entry.height)")
                    if entry.isVideo { Text(mediaDuration(entry.duration)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity,alignment: .leading)

            VStack(alignment: .trailing,spacing: 5) {
                Text(Date(timeIntervalSince1970: Double(entry.modified) / 1000),format: .dateTime.month(.abbreviated).day().year())
                Text(ByteCountFormatter.string(fromByteCount: entry.size,countStyle: .file))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()

            Color.clear.frame(width: 30,height: 26)
        }
        .padding(9)
        .background(selected ? AppTheme.blue.opacity(0.12) : AppTheme.card(for: colorScheme),in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? AppTheme.blue : Color.primary.opacity(0.07),lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct MediaPreviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: MediaEntry

    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack {
                VStack(alignment: .leading,spacing: 4) {
                    Text(entry.name).font(.title2.bold()).lineLimit(1).streamSensitive()
                    Text(entry.isVideo ? "Video thumbnail" : "Photo preview").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download",systemImage: "arrow.down.circle") { model.downloadGallery([entry.id]) }
                Button("Close") { dismiss() }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.black)
                if let image = model.galleryThumbnail(for: entry) {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                } else {
                    ProgressView("Loading preview…").foregroundStyle(.white)
                }
                if entry.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 52)).foregroundStyle(.white.opacity(0.9)) }
            }
            .frame(minWidth: 560,minHeight: 420)
            .streamSensitive(strongBlur: true)
            HStack(spacing: 18) {
                Label(entry.isVideo ? "Video" : "Photo",systemImage: entry.isVideo ? "film" : "photo")
                Label("\(entry.width) × \(entry.height)",systemImage: "aspectratio")
                if entry.isVideo { Label(mediaDuration(entry.duration),systemImage: "clock") }
                Label(ByteCountFormatter.string(fromByteCount: entry.size,countStyle: .file),systemImage: "internaldrive")
                Spacer()
                Text(Date(timeIntervalSince1970: Double(entry.modified) / 1000),format: .dateTime.month(.abbreviated).day().year().hour().minute())
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .onAppear { model.requestGalleryThumbnail(entry) }
    }
}

private func mediaDuration(_ milliseconds: Int64) -> String {
    let seconds = max(0,milliseconds / 1000)
    return String(format: "%d:%02d",seconds / 60,seconds % 60)
}

private struct MediaCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var model: AppModel
    let entry: MediaEntry
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                if let image = model.galleryThumbnail(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity,maxHeight: .infinity)
                        .clipped()
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: entry.isVideo ? "film" : "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                if entry.isVideo { Label(duration,systemImage: "play.fill").font(.caption.weight(.semibold)).padding(6).foregroundStyle(.white).background(.black.opacity(0.72),in: Capsule()).padding(7) }
                if selected { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Color.white,AppTheme.blue).padding(8) }
            }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .contentShape(Rectangle())
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .streamSensitive(strongBlur: true)
            Text(entry.name).font(.callout.weight(.medium)).lineLimit(1).streamSensitive()
            HStack { Text("\(entry.width)×\(entry.height)"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: entry.size,countStyle: .file)) }.font(.caption).foregroundStyle(.secondary)
        }
            .frame(maxWidth: .infinity,alignment: .leading)
            .padding(8)
            .background(selected ? AppTheme.blue.opacity(0.12) : AppTheme.card(for: colorScheme),in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? AppTheme.blue : Color.primary.opacity(0.07),lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    private var duration: String { mediaDuration(entry.duration) }
}

struct FileTransferView: View {
    @EnvironmentObject var model: AppModel
    @State private var direction = "All"
    private var records: [TransferRecord] { model.transfers.filter { direction == "All" || (direction == "Received" ? $0.incoming : !$0.incoming) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 20) {
                HStack(alignment: .top) { SectionHeading(title: "File Transfer",subtitle: "Live progress and transfer history across every device."); Spacer(); Button("Send files…",systemImage: "paperplane") { model.chooseFiles() }.disabled(model.connected.isEmpty) }
                HStack { Label("Receiving folder",systemImage: "folder"); Text(model.receiveFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).streamSensitive(); Spacer(); Button("Change…") { model.chooseReceiveFolder() } }
                HStack { Text("Transfers").font(.title2.bold()); Spacer(); Picker("Show",selection: $direction) { ForEach(["All","Sent","Received"],id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 260) }
                if records.isEmpty { EmptyPanel(symbol: "arrow.up.arrow.down.circle",title: "No file transfers yet",subtitle: "Downloads from Photos and Files, and batches sent from either device, appear here.").frame(minHeight: 300) }
                else { LazyVStack(spacing: 14) { ForEach(records) { FileTransferCard(transfer: $0) } } }
            }.padding(28)
        }
    }
}

private enum RemoteDragKind { case file, gallery }
private struct RemoteDragItem { var id: String; var name: String; var mime: String; var kind: RemoteDragKind; var directory = false }

@MainActor private final class RemoteDragBatchCoordinator {
    weak var model: AppModel?
    let phoneId: String
    let items: [RemoteDragItem]
    private var started = false
    private var finished = false
    private var finalError: Error?
    private var completions: [(Error?) -> Void] = []

    init(model: AppModel,phoneId: String,items: [RemoteDragItem]) {
        self.model = model; self.phoneId = phoneId; self.items = items
    }

    func writePromise(to promisedURL: URL,completion: @escaping (Error?) -> Void) {
        if finished { completion(finalError); return }
        completions.append(completion)
        guard !started else { return }
        started = true
        guard let model,let kind = items.first?.kind else { finish(StoreError(detail: "Android Sync closed before the download started.")); return }
        let folder = promisedURL.deletingLastPathComponent()
        let done: (Error?) -> Void = { [weak self] error in self?.finish(error) }
        switch kind {
        case .file: model.downloadRemoteFiles(items.map(\.id),phoneId: phoneId,destinationFolder: folder,completion: done)
        case .gallery: model.downloadGallery(items.map(\.id),phoneId: phoneId,destinationFolder: folder,completion: done)
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true; finalError = error
        let callbacks = completions; completions.removeAll()
        callbacks.forEach { $0(error) }
    }
}

private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let item: RemoteDragItem
    let coordinator: RemoteDragBatchCoordinator
    init(item: RemoteDragItem,coordinator: RemoteDragBatchCoordinator) { self.item = item; self.coordinator = coordinator }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { item.name }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor [coordinator] in coordinator.writePromise(to: url,completion: completionHandler) }
    }
}

private struct RemoteContentDragSource: NSViewRepresentable {
    let model: AppModel
    let phoneId: String
    let items: [RemoteDragItem]
    func makeNSView(context: Context) -> PromiseDragView { PromiseDragView() }
    func updateNSView(_ view: PromiseDragView,context: Context) {
        view.model = model; view.phoneId = phoneId; view.items = Array(items.prefix(100)); view.drawsControl = true; view.onClick = nil; view.needsDisplay = true
    }
}

private struct RemoteContentCardDragSource: NSViewRepresentable {
    let model: AppModel
    let phoneId: String
    let items: [RemoteDragItem]
    let onClick: () -> Void
    var onDoubleClick: (() -> Void)? = nil
    func makeNSView(context: Context) -> PromiseDragView {
        let view = PromiseDragView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: PromiseDragView,context: Context) {
        view.model = model; view.phoneId = phoneId; view.items = Array(items.prefix(100)); view.drawsControl = false; view.onClick = onClick; view.onDoubleClick = onDoubleClick; view.needsDisplay = true
    }
}

private final class PromiseDragView: NSView, NSDraggingSource {
    weak var model: AppModel?
    var phoneId = ""
    var items: [RemoteDragItem] = []
    var drawsControl = true
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?
    private var beganDrag = false
    override var intrinsicContentSize: NSSize { NSSize(width: 190,height: 34) }
    override func draw(_ dirtyRect: NSRect) {
        guard drawsControl else { return }
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds,xRadius: 8,yRadius: 8).fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5,dy: 0.5),xRadius: 8,yRadius: 8).stroke()
        let text = "⇲  Drag \(items.count) selected to Finder" as NSString
        text.draw(at: NSPoint(x: 12,y: max(7,(bounds.height - 16) / 2)),withAttributes: [.font: NSFont.systemFont(ofSize: 12,weight: .medium),.foregroundColor: NSColor.labelColor])
    }
    override func mouseDown(with event: NSEvent) { mouseDownEvent = event; beganDrag = false }
    override func mouseDragged(with event: NSEvent) {
        guard !beganDrag, let model, !items.isEmpty else { return }
        beganDrag = true
        let coordinator = RemoteDragBatchCoordinator(model: model,phoneId: phoneId,items: items)
        let draggingItems: [NSDraggingItem] = items.map { item in
            let delegate = RemoteFilePromiseDelegate(item: item,coordinator: coordinator)
            let type = item.directory ? UTType.folder.identifier : (UTType(mimeType: item.mime)?.identifier ?? UTType.data.identifier)
            let provider = NSFilePromiseProvider(fileType: type,delegate: delegate); provider.userInfo = delegate
            let dragging = NSDraggingItem(pasteboardWriter: provider)
            let image = NSWorkspace.shared.icon(for: UTType(type) ?? .data); image.size = NSSize(width: 32,height: 32)
            dragging.setDraggingFrame(NSRect(x: 0,y: 0,width: 32,height: 32),contents: image)
            return dragging
        }
        beginDraggingSession(with: draggingItems,event: mouseDownEvent ?? event,source: self)
        mouseDownEvent = nil
    }
    override func mouseUp(with event: NSEvent) {
        if !beganDrag {
            if event.clickCount > 1,onDoubleClick != nil { onDoubleClick?() }
            else { onClick?() }
        }
        mouseDownEvent = nil
        beganDrag = false
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
