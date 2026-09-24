import Foundation

/// Text safe to send to the operating system's notification service.
public struct NotificationPreview: Equatable {
    public let title: String
    public let subtitle: String
    public let body: String
    public let hidden: Bool

    public init(sourceApp: String, title: String, body: String, privacyEnabled: Bool) {
        hidden = privacyEnabled
        if privacyEnabled {
            self.title = sourceApp.isEmpty ? "Android Sync" : sourceApp
            subtitle = ""
            self.body = "Content hidden because Blur / Stream Mode is enabled."
        } else {
            self.title = title.isEmpty ? sourceApp : title
            subtitle = sourceApp
            self.body = body
        }
    }
}
