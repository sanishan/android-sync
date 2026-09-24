# Android Sync

Native Android and macOS apps for private synchronization over your local network. Created by **Muhammad Sanaullah** · **AndroidSync.com**.

## Screenshots

### macOS

![Android Sync notifications on macOS](screenshots/macos.webp)

### Android

<img src="screenshots/android.webp" alt="Android Sync file sharing on Android" width="320">

## Features

- Searchable Android notification inbox on Mac, with replies when supported by the source app.
- Clipboard text, links and images, with searchable encrypted history on Mac.
- Resumable file transfers with SHA256 integrity checks.
- Android photo and shared-storage browsing with the required permissions.
- Optional carrier SMS, contacts, call history and call controls. Call audio stays on the phone. MMS and RCS are not supported.
- Screen mirroring with fresh Android capture consent and optional remote control.
- Privacy Mode blurs supported sensitive content. Hover to reveal on Mac. Desktop alerts show the source app and a hidden-content notice while Blur / Stream Mode is enabled.
- Encrypted pairing, separate permissions for each Mac, and no AndroidSync account or cloud relay.

Android limits background clipboard access. Use capture while Android Sync is visible, Android's Share action, or manual capture. Privacy Mode does not hide other apps or the mirrored phone screen; revealed items can appear in recordings.

## Build Android

Install Android Studio or the Android SDK with platform 37 and a Java runtime compatible with Gradle 9.6 (JDK 17 or newer). Android 12 or newer is required to run the app.

Open `android` in Android Studio to configure the SDK, or set `ANDROID_HOME` to its location. Machine-specific paths belong in an untracked `android/local.properties` file. From the repository root:

```sh
./android/gradlew -p android :app:assembleLocalFullDebug :app:assembleStandardDebug
```

Outputs:

- `android/app/build/outputs/apk/localFull/debug/app-localFull-debug.apk`
- `android/app/build/outputs/apk/standard/debug/app-standard-debug.apk`

The localFull flavor includes optional SMS, shared-storage browsing and remote-control permissions. The standard flavor omits these restricted capabilities. Debug builds use a locally generated debug key; no signing keys are included.

## Build macOS

Install Xcode with the macOS SDK. The app requires macOS 14 or newer. Open `macOS/AndroidSync.xcodeproj`, select **AndroidSync** and your Mac, then build and run. The project includes its source and resources; no project or icon generator is needed.

For a universal Intel and Apple Silicon build, run from the repository root:

```sh
xcodebuild -project macOS/AndroidSync.xcodeproj \
  -scheme AndroidSync -configuration Release \
  -derivedDataPath build/macOS \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
codesign --force --deep --sign - \
  build/macOS/Build/Products/Release/AndroidSync.app
```

### Direct Swift build alternative

If Xcode's build service stalls, the same source can be compiled and packaged directly. Run these commands from the repository root with the Xcode command line tools selected:

```sh
mkdir -p build/macOS
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -parse-as-library -O \
    -target "$arch-apple-macos14.0" \
    core/Sources/SyncCore/*.swift macOS/AndroidSync/*.swift \
    -o "build/macOS/AndroidSync-$arch"
done
APP=build/macOS/AndroidSync.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools"
lipo -create build/macOS/AndroidSync-arm64 build/macOS/AndroidSync-x86_64 \
  -output "$APP/Contents/MacOS/AndroidSync"
cp macOS/AndroidSync/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable AndroidSync' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.androidsync.mac' "$APP/Contents/Info.plist"
cp macOS/AndroidSync/AndroidSync.icns "$APP/Contents/Resources/"
cp macOS/AndroidSync/Tools/adb macOS/AndroidSync/Tools/NOTICE.txt "$APP/Contents/Resources/Tools/"
codesign --force --deep --sign - --options runtime \
  --entitlements macOS/AndroidSync/AndroidSync.entitlements "$APP"
codesign --verify --deep --strict "$APP"
```

The bundled `macOS/AndroidSync/Tools/adb` is a runtime dependency for optional Advanced Mirroring. Its third-party license notices are included beside it.

### Apple signing and notarization

Muhammad Sanaullah does not currently have a paid Apple Developer Program membership. Android Sync is not signed with an Apple Developer ID certificate or notarized by Apple. Local ad hoc signing does not verify the developer's identity with Apple.

You can build a personal local copy without paid membership. If you have your own Developer ID Application certificate, configure your team in Xcode, keep Hardened Runtime enabled, sign bundled executable code including ADB, and follow Apple's [signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) guides. Signing and notarization are separate steps. Keep signing credentials on your own Mac.

## Install and pair

1. Install your chosen APK on Android. If prompted, allow the file app to install that package.
2. Move your built `AndroidSync.app` to Applications and open it. For downloaded builds blocked by macOS, review [Apple's instructions](https://support.apple.com/en-us/102445). If you trust the source, the app-specific exception is in **System Settings → Privacy & Security → Open Anyway** after a blocked launch. Do not override a malware warning.
3. Connect both devices to the same private network. Allow Local Network access on Mac.
4. In Mac **Devices**, create an invitation. On Android, scan its QR code or use invitation text. Pair each Mac separately.
5. Enable Android notification access and Android Sync notification permission for mirroring. Allow Mac notifications for native alerts.
6. Enable clipboard sharing and grant optional file, SMS, contacts or remote-control permissions only for the features you use. Review Android battery restrictions if background connectivity stops.

Received files go to **Downloads / Android Sync** by default. You can choose a receive folder on Mac. If pairing fails, check the firewall and Wi-Fi client isolation, or use the local address shown in the invitation.

For public spaces and recording, enable **Settings → Privacy → Blur Sensitive Information (Stream Mode)** on Mac. Enable Stream Mode separately on Android. Keep the pointer away from sensitive items while recording.

## License

[Android Sync Personal Source License 1.0](LICENSE) permits personal, noncommercial use and private modification. Commercial use and redistribution require prior written permission. Preserve the **Android Sync** name, **AndroidSync.com** attribution, and **Muhammad Sanaullah** copyright notice. Signing or modifying a copy does not transfer ownership.

This is source-available software, not OSI-approved open source. Third-party components retain their own licenses. Installation instructions are in this README; the LICENSE defines usage rights.
