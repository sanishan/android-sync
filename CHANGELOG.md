# Changelog

## 1.1.2 — 2026-09-26

- Fix Mirror Stream freezes after congestion by preserving H.264 frame dependencies and requesting a fresh keyframe when needed.
- Recover the Mac decoder after missing frames or decoder errors instead of continuing with an invalid reference frame.
- Keep idle screen-sharing connections alive and handle encoder commands on the encoder loop.
- Add regression tests for video queue congestion, stream recovery and the Mac decoder.
- Increase Android version code and macOS build number to 11. Update both apps for the full recovery improvements.

## 1.1.1 — 2026-09-26

- Sign Android release distribution with the permanent AndroidSync signing key.
- Distribute the universal Mac app with Developer ID signing, hardened runtime and Apple notarization.
- Add detailed signing, notarization and source-build instructions to the README.
- Require Android signing credentials for release workflow success and remove temporary key material after the job.
- Increase Android version code and macOS build number to 10.

Restore 22 Android and 26 Swift unit tests in the source repository so verification runs execute the actual test suites.


## 1.1 — 2026-09-25

### Added

- Binary file streaming over authenticated TLS, avoiding Base64 expansion and per-chunk response waits.
- Optional unencrypted local TCP file transfers, authorized with per-batch tokens exchanged over the authenticated control connection.
- A transfer-mode setting that synchronizes across paired devices and persists across restarts.

### Improved

- Bounded transfer buffers, durable partial-file checkpoints approximately every 8 MiB, and resume from the receiver's saved offset.
- SHA-256 verification before received files become available.
- Throttled progress updates to reduce interface work.
- Compatibility with the original Base64/JSON transfer path for older paired app versions.

### Transfer privacy

Encrypted Wi-Fi remains the default. Insecure mode exposes file bytes to anyone able to observe the local network; it is not guaranteed to be faster. Disabling it cancels active unencrypted batches, which must be restarted over TLS. Notifications, clipboard, pairing and transfer authorization remain on the authenticated TLS control connection.

## 1.0.0-local — 2026-09-24

- Initial packaged Android and universal macOS release.
- Notification and clipboard synchronization, file sharing, phone content browsing and optional mirroring capabilities.
- Privacy Mode blur and hidden-content desktop notification previews.
- Full-glass app icon with correctly sized macOS menu bar artwork.
