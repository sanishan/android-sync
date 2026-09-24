import SwiftUI
import AppKit
import Darwin

private final class SingleInstanceGuard {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquireOrExit() -> SingleInstanceGuard {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.androidsync.mac"
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleIdentifier).lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                .activate(options: [.activateAllWindows])
            Darwin.exit(EXIT_SUCCESS)
        }
        return SingleInstanceGuard(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

@main struct AndroidSyncApp: App {
    // MenuBarExtra uses the NSImage's intrinsic size when creating its status item.
    // A SwiftUI frame alone does not constrain an ICNS image in the menu bar.
    private static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let artwork = NSImage(named: "AndroidSync")
        let icon = NSImage(size: size, flipped: false) { bounds in
            artwork?.draw(in: bounds)
            return true
        }
        icon.isTemplate = false
        return icon
    }()

    private let singleInstanceGuard: SingleInstanceGuard
    @StateObject private var model: AppModel
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    private var preferredColorScheme: ColorScheme? {
        AppAppearance(rawValue: appAppearance)?.colorScheme
    }

    init() {
        singleInstanceGuard = SingleInstanceGuard.acquireOrExit()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Android Sync", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(model.bluetoothCalls)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 860, minHeight: 610)
        }
        .defaultSize(width: 1080, height: 740)
        .commands { CommandGroup(after: .newItem) { Button("Send files…") { model.chooseFiles() }.keyboardShortcut("s", modifiers: [.command, .shift]) } }
        Window("Android Screen", id: "mirror-screen") {
            MirrorScreenWindow()
                .environmentObject(model)
                .environmentObject(model.bluetoothCalls)
                .preferredColorScheme(preferredColorScheme)
                .tint(AppTheme.blue)
                .buttonStyle(AppNeutralButtonStyle())
        }
        .defaultSize(width: 360,height: 760)
        MenuBarExtra {
            MenuView().environmentObject(model).preferredColorScheme(preferredColorScheme)
        } label: {
            Image(nsImage: Self.menuBarIcon).renderingMode(.original)
                .accessibilityLabel("Android Sync")
        }.menuBarExtraStyle(.window)
        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(preferredColorScheme)
                .buttonStyle(AppNeutralButtonStyle())
                .frame(width: 520)
                .padding(24)
        }
    }
}
