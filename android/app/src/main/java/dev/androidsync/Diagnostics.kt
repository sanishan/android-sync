package dev.androidsync

import android.net.Uri
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.Instant

data class DiagnosticRuntime(
    val version: String,
    val flavor: String,
    val manufacturer: String,
    val model: String,
    val androidVersion: String,
    val api: Int
)

/**
 * Produces support data without accepting or serializing message text, clipboard
 * content, filenames, paths, device identities, addresses, or credentials.
 */
fun buildRedactedDiagnostics(
    state: EngineState,
    capabilities: DeviceCapabilitySet,
    runtime: DiagnosticRuntime
): String {
    fun transferBucket(status: String) = when {
        status == "Completed" -> "completed"
        status.startsWith("Failed") -> "failed"
        status in setOf("Cancelled", "Declined") -> "cancelled"
        else -> "active"
    }
    val transfers = state.transfers.groupingBy { transferBucket(it.status) }.eachCount()
    val report = JSONObject()
        .put("schema", 1)
        .put("generatedAt", Instant.now().toString())
        .put("app", JSONObject().put("name", "Android Sync").put("version", runtime.version).put("flavor", runtime.flavor))
        .put("platform", JSONObject()
            .put("name", "Android")
            .put("version", runtime.androidVersion)
            .put("api", runtime.api)
            .put("manufacturer", runtime.manufacturer)
            .put("model", runtime.model))
        .put("devices", JSONObject()
            .put("paired", state.peers.size)
            .put("connected", state.connections.values.count { it == "Connected" }))
        .put("health", JSONObject()
            .put("connectionService", state.enabled)
            .put("notificationAccess", state.notificationAccess)
            .put("notificationListener", state.listenerConnected)
            .put("ownNotifications", state.postingNotifications)
            .put("batteryUnrestricted", state.batteryUnrestricted)
            .put("backgroundSetupConfirmed", state.backgroundSetupConfirmed)
            .put("clipboardPaused", state.clipboardPaused))
        .put("historyCounts", JSONObject()
            .put("clipboard", state.clipboardClips.size)
            .put("transfers", state.transfers.size))
        .put("transferStates", JSONObject(transfers))
        .put("featureGrantCounts", JSONObject()
            .put("messages", state.messageDevices.size)
            .put("screen", state.screenDevices.size)
            .put("control", state.controlDevices.size))
        .put("capabilities", JSONObject(capabilities.values.associate { it.id to it.status.name.lowercase() }))
    return report.toString(2)
}

fun SyncEngine.exportRedactedDiagnostics(uri: Uri) {
    scope.launch(Dispatchers.IO) {
        val runtime = DiagnosticRuntime(
            version = BuildConfig.VERSION_NAME,
            flavor = if (BuildConfig.LOCAL_FULL) "localFull" else "standard",
            manufacturer = Build.MANUFACTURER,
            model = Build.MODEL,
            androidVersion = Build.VERSION.RELEASE,
            api = Build.VERSION.SDK_INT
        )
        val data = buildRedactedDiagnostics(state.value, DeviceCapabilities.detect(context, state.value), runtime)
        runCatching {
            requireNotNull(context.contentResolver.openOutputStream(uri, "wt")).bufferedWriter().use { it.write(data) }
        }.onFailure { fail("Could not export diagnostics.") }
    }
}
