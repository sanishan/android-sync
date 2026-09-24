import Foundation

struct RedactedDiagnosticsReport: Codable, Equatable {
    struct App: Codable, Equatable { var name: String; var version: String; var build: String }
    struct Platform: Codable, Equatable { var name: String; var version: String; var runtimeArchitecture: String; var buildArchitectures: [String] }
    struct Devices: Codable, Equatable { var paired: Int; var connected: Int }
    struct Health: Codable, Equatable {
        var nativeAlerts: String
        var clipboardPaused: Bool
    }
    struct HistoryCounts: Codable, Equatable {
        var notifications: Int
        var clipboard: Int
        var transfers: Int
        var smsThreads: Int
        var smsMessages: Int
        var contacts: Int
    }

    var schema = 1
    var generatedAt: Date
    var app: App
    var platform: Platform
    var devices: Devices
    var health: Health
    var historyCounts: HistoryCounts
    var transferStates: [String: Int]
    var phoneCapabilityStates: [String: Int]
}
