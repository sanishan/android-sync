package dev.androidsync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticsTest {
    @Test fun reportContainsHealthButNoDeviceOrClipboardContent() {
        val secretId = "mac-secret-id"
        val secretText = "clipboard secret text"
        val state = EngineState(
            peers = listOf(MacPeer(secretId, "Personal Mac", "192.168.1.8", 7777, "f".repeat(64))),
            connections = mapOf(secretId to "Connected"),
            clipboardClips = listOf(ClipboardClip(id = "clip-id", kind = "text", text = secretText, originDevice = "Personal Mac")),
            enabled = true,
            notificationAccess = true
        )
        val capabilities = DeviceCapabilitySet(listOf(FeatureCapability("clipboard", "Clipboard", CapabilityStatus.ENABLED, "ready")))
        val report = buildRedactedDiagnostics(state, capabilities, DiagnosticRuntime("1.0.0-local", "localFull", "Test", "Phone", "16", 36))
        assertTrue(report.contains("\"paired\": 1"))
        assertTrue(report.contains("\"clipboard\": \"enabled\""))
        listOf(secretId, secretText, "Personal Mac", "192.168.1.8", "clip-id").forEach { assertFalse(report.contains(it)) }
    }
}
