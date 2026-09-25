# Changelog

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
