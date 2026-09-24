package dev.androidsync

import android.Manifest
import android.content.Intent
import android.provider.Settings
import android.os.Build
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.Image
import androidx.compose.ui.res.painterResource
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract

@Composable
fun OnboardingFlow(engine: SyncEngine, state: EngineState) {
    var step by rememberSaveable { mutableIntStateOf(0) }
    val context = LocalContext.current
    val guide = remember { DeviceCapabilities.powerGuide(context) }
    val postNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { engine.refreshPermissions(true) }
    val messagePermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { engine.refreshPermissions(true) }
    val callPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { engine.refreshPermissions(true) }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result -> result.contents?.let(engine::pair) }
    val openNotificationAccess = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); Unit }
    val scan = {
        scanner.launch(androidSyncScanOptions())
    }

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 24.dp)) {
            Spacer(Modifier.height(18.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.mipmap.ic_launcher), contentDescription = null, modifier = Modifier.size(40.dp))
                Spacer(Modifier.width(12.dp))
                Text("Android Sync", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.height(22.dp))
            StepProgress(step)
            Text("Step ${step + 1} of 6", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            Box(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                when (step) {
                    0 -> ConnectionOnboarding(state)
                    1 -> NotificationOnboarding(state, engine)
                    2 -> ClipboardOnboarding()
                    3 -> BackgroundOnboarding(state, guide, engine)
                    4 -> PairingOnboarding(state, scan)
                    else -> OptionalOnboarding(state, engine,
                        requestMessages = { messagePermissions.launch(arrayOf(Manifest.permission.READ_SMS,Manifest.permission.SEND_SMS,Manifest.permission.READ_CONTACTS)) },
                        requestCalls = { callPermissions.launch(arrayOf(Manifest.permission.ANSWER_PHONE_CALLS,Manifest.permission.READ_CALL_LOG,Manifest.permission.CALL_PHONE)) })
                }
            }
            Spacer(Modifier.height(10.dp))
            when (step) {
                0 -> {
                    Button(onClick = { engine.setEnabled(true); step = 1 }, modifier = Modifier.fillMaxWidth().height(54.dp)) { Text(if (state.enabled) "Continue" else "Start connection service") }
                    TextButton(onClick = { engine.setOnboardingComplete(true) }, modifier = Modifier.fillMaxWidth()) { Text("Set up later") }
                }
                1 -> {
                    Button(onClick = {
                        when {
                            !state.notificationAccess -> openNotificationAccess()
                            !state.postingNotifications && Build.VERSION.SDK_INT >= 33 -> postNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                            else -> step = 2
                        }
                    }, modifier = Modifier.fillMaxWidth().height(54.dp)) {
                        Text(when {
                            !state.notificationAccess -> "Open notification access"
                            !state.postingNotifications -> "Allow Android Sync alerts"
                            else -> "Continue"
                        })
                    }
                    BackButton { step = 0 }
                }
                2 -> {
                    Button(onClick = { engine.enableClipboardSync(); step = 3 }, modifier = Modifier.fillMaxWidth().height(54.dp)) { Text("Use supported clipboard sync") }
                    BackButton { step = 1 }
                }
                3 -> {
                    val ready = state.enabled && state.batteryUnrestricted && state.backgroundSetupConfirmed
                    Button(onClick = { step = 4 }, enabled = ready, modifier = Modifier.fillMaxWidth().height(54.dp)) { Text(if (ready) "Continue" else "Complete the three steps above") }
                    BackButton { step = 2 }
                }
                4 -> {
                    Button(onClick = { step = 5 }, enabled = state.peers.isNotEmpty(), modifier = Modifier.fillMaxWidth().height(54.dp)) { Text(if (state.peers.isEmpty()) "Pair a Mac to continue" else "Continue") }
                    BackButton { step = 3 }
                }
                else -> {
                    Button(onClick = { engine.setOnboardingComplete(true) }, modifier = Modifier.fillMaxWidth().height(54.dp)) { Text("Finish setup") }
                    BackButton { step = 4 }
                }
            }
            Spacer(Modifier.height(10.dp))
        }
    }
}

@Composable private fun BackButton(action: () -> Unit) { TextButton(onClick = action, modifier = Modifier.fillMaxWidth()) { Text("Back") } }

@Composable
private fun StepProgress(step: Int) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        repeat(6) { index ->
            LinearProgressIndicator(
                progress = { if (index <= step) 1f else 0f },
                modifier = Modifier.weight(1f).height(7.dp),
                color = MaterialTheme.colorScheme.secondary,
                trackColor = MaterialTheme.colorScheme.background
            )
        }
    }
}

@Composable
private fun ConnectionOnboarding(state: EngineState) {
    Column {
        OnboardingHeader(Icons.Outlined.Sync, "Required", "Keep your devices connected", "Android Sync uses a visible local connection service. It has no account or cloud relay.")
        StatusList(
            StatusLine(Icons.Outlined.Wifi, "Local connection service", "Reconnects paired Macs after network changes", state.enabled),
            StatusLine(Icons.Outlined.Lock, "Encrypted device identity", "Stored in Android Keystore", true),
            StatusLine(Icons.Outlined.CloudOff, "Local transport", "Wi-Fi or USB-tethered local IP", true)
        )
        InfoBanner("Android shows a persistent notification while device connections are enabled.")
    }
}

@Composable
private fun NotificationOnboarding(state: EngineState, engine: SyncEngine) {
    Column {
        OnboardingHeader(Icons.Outlined.NotificationsActive, "Required", "Mirror notifications", "See Android alerts on every paired Mac and reply only when the source app provides a live text-reply action.")
        StatusList(
            StatusLine(Icons.Outlined.ListAlt, "Notification listener", "Read active alerts and dismiss on phone", state.notificationAccess),
            StatusLine(Icons.Outlined.Reply, "Supported replies", "Uses the notification's current RemoteInput action", state.notificationAccess && state.listenerConnected),
            StatusLine(Icons.Outlined.Campaign, "Android Sync alerts", "Connection and transfer status", state.postingNotifications)
        )
        if (state.notificationAccess && state.postingNotifications) SyncOutlinedButton(onClick = engine::postTestNotification, modifier = Modifier.fillMaxWidth()) { Text("Send a test notification") }
        Spacer(Modifier.height(10.dp))
        InfoBanner("Accepted means Android invoked the action. Uncertain replies are never sent again automatically.")
    }
}

@Composable
private fun ClipboardOnboarding() {
    Column {
        OnboardingHeader(Icons.Outlined.ContentPaste, "Required", "Sync your clipboard", "Copy text, links, and images on this device, then paste them on a paired Mac.")
        FeatureList(
            Triple(Icons.Outlined.PlayCircle, "Automatic while visible", "Android Sync captures new clips while it has focus."),
            Triple(Icons.Outlined.Notifications, "One-tap background fallback", "Use the persistent notification or Quick Settings tile."),
            Triple(Icons.Outlined.Share, "Share from any app", "Choose Share → Android Sync for text, links, and images."),
            Triple(Icons.Outlined.Security, "Sensitive clips are skipped", "Platform-marked sensitive content is not synchronized.")
        )
        InfoBanner("Android has no general clipboard permission. Your current keyboard stays active, and Android Sync reports the capture methods that actually work on this device.")
    }
}

@Composable
private fun BackgroundOnboarding(state: EngineState, guide: PowerGuide, engine: SyncEngine) {
    Column {
        OnboardingHeader(Icons.Outlined.BatterySaver, "Required", "Keep connections active", "Apply the recommended ${guide.vendor} settings for screen-off reconnection.")
        ActionStatusCard(Icons.Outlined.Sync, "Persistent connection", "Visible connected-device service", state.enabled, if (state.enabled) "Enabled" else "Start") { engine.setEnabled(true) }
        ActionStatusCard(Icons.Outlined.BatteryChargingFull, "Battery usage", "Allow unrestricted background work", state.batteryUnrestricted, if (state.batteryUnrestricted) "Unrestricted" else "Open") { DeviceCapabilities.openPowerSettings(engine.context) }
        ActionStatusCard(Icons.Outlined.BedtimeOff, guide.title, guide.detail, state.backgroundSetupConfirmed, if (state.backgroundSetupConfirmed) "Confirmed" else "Open") { DeviceCapabilities.openPowerSettings(engine.context) }
        if (!state.backgroundSetupConfirmed) SyncOutlinedButton(onClick = { engine.confirmBackgroundSetup() }, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Outlined.CheckCircle, null); Spacer(Modifier.width(8.dp)); Text("I completed the ${guide.vendor} settings")
        }
        Spacer(Modifier.height(10.dp))
        InfoBanner("Some vendors can still stop background work under extreme battery or memory pressure. Setup reports the current service health.")
    }
}

@Composable
private fun PairingOnboarding(state: EngineState, scan: () -> Unit) {
    Column {
        OnboardingHeader(Icons.Outlined.QrCodeScanner, "Required", "Pair your first Mac", "Open Devices in Android Sync for Mac and scan its expiring invitation. Pair every Mac separately.")
        StatusList(
            StatusLine(Icons.Outlined.DesktopMac, "Trusted Macs", if (state.peers.isEmpty()) "No Mac paired yet" else "${state.peers.size} paired", state.peers.isNotEmpty()),
            StatusLine(Icons.Outlined.Security, "Pinned identity", "Unknown and changed identities are rejected", state.peers.isNotEmpty())
        )
        Button(onClick = scan, enabled = !state.pairing, modifier = Modifier.fillMaxWidth().height(54.dp)) {
            Icon(Icons.Outlined.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text(if (state.pairing) "Pairing…" else "Scan Mac invitation")
        }
        Spacer(Modifier.height(12.dp))
        InfoBanner("If local discovery is blocked, finish setup and use the manual invitation and address fields on Devices.")
    }
}

@Composable
private fun OptionalOnboarding(state: EngineState, engine: SyncEngine, requestMessages: () -> Unit, requestCalls: () -> Unit) {
    Column {
        OnboardingHeader(Icons.Outlined.Extension, "Optional", "Choose extra features", "Each paired Mac receives its own feature access. You can change these later.")
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
            Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OptionalToggle(Icons.Outlined.FolderCopy, "File transfer", "Send and receive resumable batches", state.fileTransferEnabled, engine::setFileTransferEnabled)
                if (BuildConfig.LOCAL_FULL) {
                    HorizontalDivider()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.FolderOpen,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(30.dp))
                        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text("Mac storage browser",fontWeight = FontWeight.SemiBold); Text(if (state.allFilesAccess) "Shared storage available" else "Optional All files access; private app data excluded",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Button(onClick = engine::openAllFilesSettings) { Text(if (state.allFilesAccess) "Review" else "Allow") }
                    }
                }
                if (BuildConfig.LOCAL_FULL) {
                    HorizontalDivider()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Sms,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(30.dp))
                        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text("Carrier SMS and contacts",fontWeight = FontWeight.SemiBold); Text(if (state.messagePermissions) "Permission ready; grant each Mac separately in Devices" else "Optional SMS-only conversations and contact names",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Button(onClick = requestMessages) { Text(if (state.messagePermissions) "Review" else "Allow") }
                    }
                    HorizontalDivider()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.PhoneInTalk,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(30.dp))
                        val ready = listOf(Manifest.permission.ANSWER_PHONE_CALLS,Manifest.permission.READ_CALL_LOG,Manifest.permission.CALL_PHONE).all { engine.context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
                        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text("Cellular calls, history & dialing",fontWeight = FontWeight.SemiBold); Text(if (ready) "All three Android phone permissions granted" else "Tap Allow to request Call logs, Place calls, and Answer calls",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Button(onClick = requestCalls) { Text(if (ready) "Review" else "Allow") }
                    }
                    HorizontalDivider()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.TouchApp,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(30.dp))
                        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text("Remote control",fontWeight = FontWeight.SemiBold); Text(if (state.accessibilityControl) "Accessibility active; grant each Mac separately in Devices" else "Optional taps, swipes, navigation, and accessible text insertion",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        Button(onClick = engine::openAccessibilitySettings) { Text(if (state.accessibilityControl) "Review" else "Enable") }
                    }
                }
                HorizontalDivider()
                OptionalToggle(Icons.Outlined.PhoneDisabled, "Call audio", "Disabled until two-way audio passes device tests", false, {}, false)
            }
        }
        Spacer(Modifier.height(14.dp))
        InfoBanner("Contacts, carrier SMS, and screen control are requested only when you enable those features.")
    }
}

@Composable
private fun OptionalToggle(icon: ImageVector, title: String, detail: String, checked: Boolean, change: (Boolean) -> Unit, enabled: Boolean = true) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(30.dp))
        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text(title, fontWeight = FontWeight.SemiBold); Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Switch(checked, change, enabled = enabled)
    }
}

@Composable
private fun OnboardingHeader(icon: ImageVector, badge: String, title: String, body: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Surface(shape = RoundedCornerShape(32.dp), color = MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.size(116.dp)) { Box(contentAlignment = Alignment.Center) { Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(58.dp)) } }
        Spacer(Modifier.height(14.dp)); AssistChip(onClick = {}, label = { Text(badge) })
        Text(title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(7.dp)); Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.height(18.dp))
    }
}

@Composable
private fun FeatureList(vararg rows: Triple<ImageVector, String, String>) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column { rows.forEachIndexed { index, row ->
            Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(row.first, null, tint = MaterialTheme.colorScheme.primary)
                Column(Modifier.padding(start = 14.dp)) { Text(row.second, fontWeight = FontWeight.Medium); Text(row.third, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            if (index < rows.lastIndex) HorizontalDivider()
        } }
    }
    Spacer(Modifier.height(14.dp))
}

private data class StatusLine(val icon: ImageVector, val title: String, val detail: String, val complete: Boolean)

@Composable
private fun StatusList(vararg rows: StatusLine) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column { rows.forEachIndexed { index, row ->
            Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(row.icon, null, tint = MaterialTheme.colorScheme.primary)
                Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text(row.title, fontWeight = FontWeight.Medium); Text(row.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                Icon(if (row.complete) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked, null, tint = if (row.complete) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (index < rows.lastIndex) HorizontalDivider()
        } }
    }
    Spacer(Modifier.height(14.dp))
}

@Composable
private fun ActionStatusCard(icon: ImageVector, title: String, detail: String, complete: Boolean, actionLabel: String, action: () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow), modifier = Modifier.padding(bottom = 10.dp)) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = if (complete) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text(title, fontWeight = FontWeight.Medium); Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            if (complete) Icon(Icons.Outlined.CheckCircle, null, tint = MaterialTheme.colorScheme.tertiary) else TextButton(onClick = action) { Text(actionLabel) }
        }
    }
}

@Composable
fun InfoBanner(text: String) {
    Surface(color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.65f), shape = RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.Top) { Icon(Icons.Outlined.Info, null, tint = MaterialTheme.colorScheme.primary); Text(text, modifier = Modifier.padding(start = 12.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
    Spacer(Modifier.height(14.dp))
}
