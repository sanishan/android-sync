package dev.androidsync

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.Settings
import android.os.Build
import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.IntentSenderRequest
import androidx.compose.foundation.Image
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.graphics.drawable.toBitmap
import com.journeyapps.barcodescanner.ScanContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SyncScreen(engine: SyncEngine, shared: SharedIntent?, consumeShare: () -> Unit) {
    val state by engine.state.collectAsState()
    var page by rememberSaveable { mutableIntStateOf(0) }
    var pendingFiles by remember { mutableStateOf<List<Uri>>(emptyList()) }
    var preferredFileMac by rememberSaveable { mutableStateOf<String?>(null) }
    var showFileReview by remember { mutableStateOf(false) }
    var showManualPair by remember { mutableStateOf(false) }
    var shareText by remember { mutableStateOf<SharedIntent?>(null) }
    var dismissedIncoming by remember { mutableStateOf(setOf<String>()) }
    val context = LocalContext.current
    val postNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { engine.refreshPermissions(true) }
    val messagePermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { engine.refreshPermissions(true) }
    val callPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { engine.refreshPermissions(true) }
    val diagnostics = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri -> uri?.let(engine::exportRedactedDiagnostics) }
    val companionApproval = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { engine.refreshPermissions(true) }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result -> result.contents?.let(engine::pair) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        val batch = (pendingFiles + uris).distinct()
        if (batch.size > 100) engine.fail("Choose up to 100 files in a batch.")
        else if (batch.isNotEmpty()) { pendingFiles = batch; showFileReview = true }
    }
    val titles = listOf("Devices", "Clipboard", "Files", "Settings")
    val icons = listOf(Icons.Outlined.Devices, Icons.Outlined.ContentPaste, Icons.Outlined.FolderOpen, Icons.Outlined.Tune)

    LaunchedEffect(shared) {
        when {
            shared?.files?.isNotEmpty() == true -> { pendingFiles = shared.files.take(100); page = 2; showFileReview = true }
            shared?.text != null -> { shareText = shared; page = 1 }
        }
    }

    CompositionLocalProvider(LocalStreamMode provides state.streamModeEnabled) {
    BoxWithConstraints {
        val wide = maxWidth >= 720.dp
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(titles[page], style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold) },
                    actions = {
                        if (state.streamModeEnabled) Icon(Icons.Outlined.VisibilityOff, "Stream Mode enabled", tint = MaterialTheme.colorScheme.tertiary, modifier = Modifier.padding(end = 8.dp))
                        when (page) {
                            0 -> {
                                IconButton(onClick = { scanner.launch(androidSyncScanOptions()) }) { Icon(Icons.Outlined.QrCodeScanner,"Scan QR invitation") }
                                IconButton(onClick = { showManualPair = true }) { Icon(Icons.Outlined.Add,"Enter invitation") }
                            }
                            1 -> Switch(checked = !state.clipboardPaused,onCheckedChange = { engine.toggleClipboard() },modifier = Modifier.padding(end = 12.dp))
                        }
                    }
                )
            },
            bottomBar = {
                if (!wide) NavigationBar { titles.forEachIndexed { index, title -> NavigationBarItem(selected = page == index, onClick = { page = index }, icon = { Icon(icons[index], title) }, label = { Text(title) }) } }
            }
        ) { padding ->
            Row(Modifier.fillMaxSize().padding(padding)) {
                if (wide) NavigationRail {
                    Spacer(Modifier.height(12.dp))
                    titles.forEachIndexed { index, title -> NavigationRailItem(selected = page == index, onClick = { page = index }, icon = { Icon(icons[index], title) }, label = { Text(title) }) }
                }
                val content = Modifier.weight(1f).fillMaxHeight()
                when (page) {
                    0 -> DevicesScreen(state, engine, content,
                        associate = { engine.requestCompanionAssociation { companionApproval.launch(IntentSenderRequest.Builder(it).build()) } })
                    1 -> ClipboardScreen(state, engine, content)
                    2 -> FileSharingPage(engine,state,content,preferredFileMac,{ preferredFileMac = it }) { picker.launch(arrayOf("*/*")) }
                    else -> SetupScreen(state, engine, content,
                        openNotificationAccess = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) },
                        requestOwnNotifications = { if (Build.VERSION.SDK_INT >= 33) postNotifications.launch(Manifest.permission.POST_NOTIFICATIONS) else engine.refreshPermissions(true) },
                        openPower = { DeviceCapabilities.openPowerSettings(context) },
                        requestMessages = { messagePermissions.launch(arrayOf(Manifest.permission.READ_SMS,Manifest.permission.SEND_SMS,Manifest.permission.READ_CONTACTS)) },
                        requestCalls = { callPermissions.launch(arrayOf(Manifest.permission.READ_CALL_LOG,Manifest.permission.CALL_PHONE,Manifest.permission.ANSWER_PHONE_CALLS)) },
                        exportDiagnostics = { diagnostics.launch("android-sync-diagnostics.json") }
                    )
                }
            }
        }
    }

    if (state.error != null) AlertDialog(onDismissRequest = engine::clearError, title = { Text("Android Sync") }, text = { Text(state.error!!) }, confirmButton = { TextButton(onClick = engine::clearError) { Text("OK") } })
    if (showManualPair) ManualPairDialog(engine) { showManualPair = false }

    if (showFileReview) FileBatchReviewDialog(
        engine = engine,
        state = state,
        selection = pendingFiles,
        initialMac = preferredFileMac,
        addMore = { picker.launch(arrayOf("*/*")) },
        remove = { uri -> pendingFiles = pendingFiles.filterNot { it == uri }; if (pendingFiles.isEmpty()) showFileReview = false },
        close = { showFileReview = false; if (shared?.files?.isNotEmpty() == true) consumeShare() },
        sent = { pendingFiles = emptyList(); showFileReview = false; consumeShare() }
    )

    shareText?.let { content ->
        ShareTextDialog(state, content,
            shareAll = { engine.shareText(content.text.orEmpty(), sourceApp = content.sourceApp); shareText = null; consumeShare() },
            shareOne = { macId -> engine.shareText(content.text.orEmpty(), macId, content.sourceApp); shareText = null; consumeShare() },
            dismiss = { shareText = null; consumeShare() }
        )
    }

    state.transfers.firstOrNull { it.incoming && !it.accepted && it.status == "Awaiting your acceptance" && it.offer.id !in dismissedIncoming }?.let { transfer ->
        IncomingTransferSheet(transfer, state.peers.firstOrNull { it.id == transfer.macId }?.name ?: "Mac", engine,
            dismiss = { dismissedIncoming = dismissedIncoming + transfer.offer.id })
    }
    }

}

@Composable
private fun DevicesScreen(state: EngineState, engine: SyncEngine, modifier: Modifier, associate: () -> Unit) {
    val connected = state.connections.values.count { it == "Connected" }
    val orderedPeers = state.peers.sortedWith(compareByDescending<MacPeer> { state.connections[it.id] == "Connected" }.thenBy { it.name.lowercase() })
    LazyColumn(modifier.fillMaxSize(),contentPadding = PaddingValues(SyncPagePadding),verticalArrangement = Arrangement.spacedBy(SyncItemSpacing)) {
        item {
            Surface(
                color = MaterialTheme.colorScheme.tertiary.copy(alpha = .09f),
                shape = SyncCardShape,
                border = BorderStroke(1.dp,MaterialTheme.colorScheme.tertiary.copy(alpha = .35f))
            ) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp,vertical = 9.dp),verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Lock,null,tint = MaterialTheme.colorScheme.tertiary,modifier = Modifier.size(20.dp))
                    Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                        Text("Encrypted local connection",fontWeight = FontWeight.SemiBold,style = MaterialTheme.typography.bodyMedium)
                        Text("$connected connected · ${if (state.enabled) "Sync on" else "Sync off"}",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(state.enabled,engine::setEnabled)
                }
            }
        }
        item { Text(if (connected > 0) "Connected devices" else "Paired devices",style = MaterialTheme.typography.titleSmall,fontWeight = FontWeight.Bold,color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (orderedPeers.isEmpty()) item { EmptyDeviceCard() }
        items(orderedPeers,key = { it.id }) { peer ->
            PeerCard(peer,state.connections[peer.id] ?: "Offline",state.askEveryTimeFiles.contains(peer.id),state.messageDevices.contains(peer.id),state.messagePermissions,state.screenDevices.contains(peer.id),state.controlDevices.contains(peer.id),state.accessibilityControl,engine)
        }
        item {
            SyncCard {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp,vertical = 9.dp),verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Link,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(20.dp))
                    Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                        Text("Companion association",fontWeight = FontWeight.SemiBold,style = MaterialTheme.typography.bodyMedium)
                        Text(if (state.companionAssociated) "Active for background connectivity" else "Add Android's optional system association",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (state.companionAssociated) Icon(Icons.Outlined.CheckCircle,"Active",tint = MaterialTheme.colorScheme.tertiary)
                    else TextButton(onClick = associate) { Text("Add") }
                }
            }
        }
        item { Text("Use the QR or + button above to pair another Mac.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant,modifier = Modifier.padding(horizontal = 4.dp)) }
    }
}

@Composable
private fun EmptyDeviceCard() {
    SyncCard {
        Row(Modifier.fillMaxWidth().padding(14.dp),verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.DesktopMac,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(30.dp))
            Column(Modifier.padding(start = 12.dp)) {
                Text("No Macs paired",fontWeight = FontWeight.SemiBold)
                Text("Scan a QR invitation to connect.",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun PeerCard(peer: MacPeer,status: String,askEveryTimeFiles: Boolean,messagesEnabled: Boolean,messagePermissions: Boolean,screenEnabled: Boolean,controlEnabled: Boolean,accessibilityEnabled: Boolean,engine: SyncEngine) {
    var expanded by rememberSaveable(peer.id) { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val online = status == "Connected"
    SyncCard {
        Column(Modifier.fillMaxWidth().padding(12.dp),verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(shape = RoundedCornerShape(11.dp),color = MaterialTheme.colorScheme.primaryContainer,modifier = Modifier.size(44.dp)) {
                    Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.DesktopMac,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(24.dp)) }
                }
                Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        StreamSensitive(Modifier.weight(1f)) { Text(peer.name,style = MaterialTheme.typography.titleSmall,fontWeight = FontWeight.Bold,maxLines = 1,overflow = TextOverflow.Ellipsis) }
                        StreamSensitive { Text(peer.id.takeLast(6),style = MaterialTheme.typography.labelSmall,fontWeight = FontWeight.Bold,color = MaterialTheme.colorScheme.primary) }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Surface(shape = CircleShape,color = if (online) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.outline,modifier = Modifier.size(7.dp)) {}
                        Text(if (online) "Connected · Now" else status,modifier = Modifier.padding(start = 6.dp),style = MaterialTheme.typography.bodySmall,color = if (online) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                IconButton(onClick = { expanded = !expanded },modifier = Modifier.size(40.dp)) { Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,"Device permissions") }
                Box {
                    IconButton(onClick = { menu = true },modifier = Modifier.size(40.dp)) { Icon(Icons.Outlined.MoreVert,"Device actions") }
                    DropdownMenu(menu,{ menu = false }) {
                        DropdownMenuItem(text = { Text("Forget this Mac") },onClick = { menu = false; engine.forget(peer.id) },leadingIcon = { Icon(Icons.Outlined.Delete,null,tint = MaterialTheme.colorScheme.error) })
                    }
                }
            }
            if (expanded) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp),verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    DeviceCapabilityChip(Icons.Outlined.Folder,if (askEveryTimeFiles) "Files ask" else "Files auto",!askEveryTimeFiles) { engine.setAskEveryTimeFiles(peer.id,!askEveryTimeFiles) }
                    DeviceCapabilityChip(Icons.Outlined.Message,"Messages",messagesEnabled,messagePermissions) { engine.setMessageDevice(peer.id,!messagesEnabled) }
                    DeviceCapabilityChip(Icons.Outlined.ScreenShare,"Mirror",screenEnabled) { engine.setScreenDevice(peer.id,!screenEnabled) }
                    if (BuildConfig.LOCAL_FULL) DeviceCapabilityChip(Icons.Outlined.TouchApp,"Control",controlEnabled,accessibilityEnabled && screenEnabled) { engine.setControlDevice(peer.id,!controlEnabled) }
                }
                Text(if (messagesEnabled) "Messages access on: this Mac can read carrier SMS, contacts, and call history." else "Messages access off: tap Messages to allow this Mac to read carrier SMS, contacts, and call history.", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                StreamSensitive { Text("${peer.host}:${peer.port}",style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }
}

@Composable
private fun DeviceCapabilityChip(icon: ImageVector,label: String,selected: Boolean,enabled: Boolean = true,onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        enabled = enabled,
        label = { Text(label,style = MaterialTheme.typography.labelMedium) },
        leadingIcon = { Icon(icon,null,modifier = Modifier.size(17.dp)) },
        shape = RoundedCornerShape(10.dp),
        border = FilterChipDefaults.filterChipBorder(enabled = enabled,selected = selected,borderColor = MaterialTheme.colorScheme.outlineVariant,selectedBorderColor = MaterialTheme.colorScheme.primary)
    )
}

@Composable
private fun ClipboardScreen(state: EngineState, engine: SyncEngine, modifier: Modifier) {
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf("All") }
    var selectedDevice by rememberSaveable { mutableStateOf<String?>(null) }
    var optionsOpen by remember { mutableStateOf(false) }
    var viewingClipId by rememberSaveable { mutableStateOf<String?>(null) }
    val deviceNames = remember(state.clipboardClips,state.peers) {
        buildMap {
            put(engine.store.phoneId,"This device")
            state.peers.forEach { put(it.id,it.name) }
            state.clipboardClips.forEach { putIfAbsent(it.originDeviceId.ifBlank { it.originDevice },it.originDevice) }
        }
    }
    val clips = remember(state.clipboardClips, query, filter, selectedDevice) {
        state.clipboardClips.filter { clip ->
            val matchesKind = when (filter) {
                "Text" -> clip.kind == "text"
                "Links" -> clip.kind == "link"
                "Images" -> clip.kind == "image"
                "Pinned" -> clip.pinned
                else -> true
            }
            (selectedDevice == null || clip.originDeviceId.ifBlank { clip.originDevice } == selectedDevice) && matchesKind &&
                (query.isBlank() || clip.text.contains(query, true) || clip.sourceApp?.contains(query, true) == true || clip.originDevice.contains(query, true))
        }
    }
    val grouped = remember(clips) { clips.groupBy { clipboardDayLabel(it.createdAt) } }
    LazyColumn(modifier.fillMaxSize(),contentPadding = PaddingValues(SyncPagePadding),verticalArrangement = Arrangement.spacedBy(SyncItemSpacing)) {
        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                item { ClipboardDeviceChip(selectedDevice == null,"All devices",Icons.Outlined.Devices) { selectedDevice = null } }
                items(deviceNames.entries.toList(),key = { it.key }) { (id,name) ->
                    ClipboardDeviceChip(selectedDevice == id,name,if (id == engine.store.phoneId) Icons.Outlined.PhoneAndroid else Icons.Outlined.DesktopMac) { selectedDevice = id }
                }
            }
        }
        item {
            Box {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text("Search clipboard") },
                    leadingIcon = { Icon(Icons.Outlined.Search,null) },
                    trailingIcon = { IconButton(onClick = { optionsOpen = true }) { Icon(Icons.Outlined.Tune,"Clipboard filters and settings") } },
                    shape = SyncCardShape
                )
                DropdownMenu(expanded = optionsOpen,onDismissRequest = { optionsOpen = false },modifier = Modifier.widthIn(min = 240.dp)) {
                    listOf("All","Pinned","Text","Links","Images").forEach { label ->
                        DropdownMenuItem(text = { Text("Show $label") },onClick = { filter = label; optionsOpen = false },trailingIcon = { if (filter == label) Icon(Icons.Outlined.Check,null,tint = MaterialTheme.colorScheme.primary) })
                    }
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("Sync clipboard now") },onClick = { optionsOpen = false; engine.shareCurrentClipboard() },enabled = !state.clipboardPaused,leadingIcon = { Icon(Icons.Outlined.Sync,null) })
                    selectedDevice?.let { deviceId ->
                        val paused = state.pausedClipboardDevices.contains(deviceId)
                        DropdownMenuItem(text = { Text(if (paused) "Resume ${deviceNames[deviceId]}" else "Pause ${deviceNames[deviceId]}") },onClick = { optionsOpen = false; engine.toggleClipboardDevice(deviceId) },leadingIcon = { Icon(if (paused) Icons.Outlined.PlayArrow else Icons.Outlined.Pause,null) })
                    }
                    HorizontalDivider()
                    listOf(256L * 1024 * 1024 to "256 MB history",DEFAULT_CLIPBOARD_QUOTA to "1 GB history",2L * 1024 * 1024 * 1024 to "2 GB history").forEach { (bytes,label) ->
                        DropdownMenuItem(text = { Text(label) },onClick = { engine.setClipboardQuota(bytes); optionsOpen = false },trailingIcon = { if (state.clipboardQuotaBytes == bytes) Icon(Icons.Outlined.Check,null,tint = MaterialTheme.colorScheme.primary) })
                    }
                    if (state.clipboardClips.isNotEmpty()) {
                        HorizontalDivider()
                        DropdownMenuItem(text = { Text("Clear local history") },onClick = { optionsOpen = false; engine.clearClipboardHistory() },leadingIcon = { Icon(Icons.Outlined.Delete,null,tint = MaterialTheme.colorScheme.error) })
                    }
                }
            }
        }
        if (clips.isEmpty()) item {
            SyncCard { Row(Modifier.padding(14.dp),verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Outlined.ContentPasteSearch,null,tint = MaterialTheme.colorScheme.primary); Text("No matching clips",modifier = Modifier.padding(start = 10.dp),color = MaterialTheme.colorScheme.onSurfaceVariant) } }
        }
        grouped.forEach { (day,itemsForDay) ->
            item(key = "day-$day") { Text(day,style = MaterialTheme.typography.titleSmall,fontWeight = FontWeight.Bold,color = MaterialTheme.colorScheme.onSurfaceVariant,modifier = Modifier.padding(top = 2.dp,start = 2.dp)) }
            items(itemsForDay,key = { it.id }) { clip -> ClipboardClipCard(clip,state,engine) { viewingClipId = clip.id } }
        }
    }
    viewingClipId?.let { clipId ->
        state.clipboardClips.firstOrNull { it.id == clipId }?.let { clip ->
            ClipboardClipDialog(clip,engine) { viewingClipId = null }
        } ?: LaunchedEffect(clipId) { viewingClipId = null }
    }
}

@Composable
private fun ClipboardClipCard(clip: ClipboardClip, state: EngineState, engine: SyncEngine, view: () -> Unit) {
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(clip.id,clip.imagePath) { if (clip.isImage && clip.imagePath == null) engine.materializeClipboardImage(clip.id) }
    val appIcon = remember(clip.sourcePackage) {
        clip.sourcePackage?.let { packageName -> runCatching { context.packageManager.getApplicationIcon(packageName).toBitmap(96, 96).asImageBitmap() }.getOrNull() }
    }
    SyncCard {
        Row(Modifier.fillMaxWidth().padding(11.dp),verticalAlignment = Alignment.CenterVertically) {
            if (clip.isImage) StreamSensitive(strongBlur = true) { CompactClipboardImage(clip.imagePath) }
            else if (appIcon != null) Image(appIcon,null,modifier = Modifier.size(42.dp).clip(RoundedCornerShape(10.dp)))
            else Surface(shape = RoundedCornerShape(10.dp),color = MaterialTheme.colorScheme.surfaceContainer,modifier = Modifier.size(42.dp)) { Box(contentAlignment = Alignment.Center) { Icon(if (clip.isLink) Icons.Outlined.Link else Icons.Outlined.TextSnippet,null,modifier = Modifier.size(21.dp)) } }
            Column(Modifier.weight(1f).padding(horizontal = 10.dp),verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    StreamSensitive(Modifier.weight(1f)) { Text("${clip.sourceApp ?: "Source unavailable"} · ${clip.originDevice}",fontWeight = FontWeight.Medium,style = MaterialTheme.typography.bodySmall,maxLines = 1,overflow = TextOverflow.Ellipsis) }
                    if (clip.pinned) Icon(Icons.Outlined.PushPin,"Pinned",tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(15.dp))
                }
                if (clip.isImage) Text("${clip.mime?.substringAfter('/')?.uppercase() ?: "IMAGE"} · ${clip.width} × ${clip.height} · ${android.text.format.Formatter.formatFileSize(context,clip.size)}",maxLines = 1,overflow = TextOverflow.Ellipsis,style = MaterialTheme.typography.bodySmall)
                else StreamSensitive { Text(clip.text,maxLines = 2,overflow = TextOverflow.Ellipsis,style = MaterialTheme.typography.bodyMedium) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(DateUtils.getRelativeTimeSpanString(clip.createdAt,System.currentTimeMillis(),DateUtils.MINUTE_IN_MILLIS).toString(),style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
                    val expected = state.connections.values.count { it == "Connected" }
                    if (expected > 0 && clip.syncedMacs.isNotEmpty()) Icon(Icons.Outlined.CheckCircle,"Synced",tint = MaterialTheme.colorScheme.tertiary,modifier = Modifier.padding(start = 6.dp).size(14.dp))
                }
            }
            OutlinedIconButton(onClick = { engine.copyClip(clip.id) },modifier = Modifier.size(40.dp),border = BorderStroke(1.dp,MaterialTheme.colorScheme.primary)) { Icon(Icons.Outlined.ContentCopy,"Copy clipboard item",modifier = Modifier.size(19.dp)) }
            OutlinedIconButton(onClick = view,modifier = Modifier.padding(start = 5.dp).size(40.dp),border = BorderStroke(1.dp,MaterialTheme.colorScheme.primary)) { Icon(Icons.Outlined.Visibility,"View full clipboard item",modifier = Modifier.size(20.dp)) }
            Box {
                IconButton(onClick = { menu = true },modifier = Modifier.size(38.dp)) { Icon(Icons.Outlined.MoreVert,"Clipboard actions") }
                DropdownMenu(menu,{ menu = false }) {
                    if (clip.isLink) DropdownMenuItem({ Text("Open link") },onClick = { menu = false; runCatching { context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(clip.text))) } },leadingIcon = { Icon(Icons.Outlined.OpenInNew,null) })
                    DropdownMenuItem({ Text(if (clip.pinned) "Unpin" else "Pin") },onClick = { menu = false; engine.toggleClipboardPin(clip.id) },leadingIcon = { Icon(Icons.Outlined.PushPin,null) })
                    DropdownMenuItem({ Text("Delete on this phone") },onClick = { menu = false; engine.deleteClipboardClip(clip.id,false) },leadingIcon = { Icon(Icons.Outlined.Delete,null) })
                    DropdownMenuItem({ Text("Delete everywhere") },onClick = { menu = false; engine.deleteClipboardClip(clip.id,true) },leadingIcon = { Icon(Icons.Outlined.DeleteForever,null) })
                }
            }
        }
    }
}

@Composable
private fun ClipboardClipDialog(clip: ClipboardClip, engine: SyncEngine, close: () -> Unit) {
    val context = LocalContext.current
    LaunchedEffect(clip.id,clip.imagePath) { if (clip.isImage && clip.imagePath == null) engine.materializeClipboardImage(clip.id) }
    Dialog(onDismissRequest = close,properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxHeight(.88f).padding(14.dp),
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
            border = BorderStroke(1.dp,MaterialTheme.colorScheme.outlineVariant)
        ) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp,end = 7.dp,top = 10.dp,bottom = 10.dp),verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (clip.isImage) Icons.Outlined.Image else if (clip.isLink) Icons.Outlined.Link else Icons.Outlined.TextSnippet,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(24.dp))
                    Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                        StreamSensitive { Text(clip.sourceApp ?: "Clipboard item",style = MaterialTheme.typography.titleMedium,fontWeight = FontWeight.Bold,maxLines = 1,overflow = TextOverflow.Ellipsis) }
                        StreamSensitive { Text("${clip.originDevice} · ${DateUtils.getRelativeTimeSpanString(clip.createdAt,System.currentTimeMillis(),DateUtils.MINUTE_IN_MILLIS)}",style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.onSurfaceVariant,maxLines = 1) }
                    }
                    if (clip.pinned) Icon(Icons.Outlined.PushPin,"Pinned",tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(19.dp))
                    if (clip.isLink) IconButton(onClick = { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(clip.text))) } }) { Icon(Icons.Outlined.OpenInNew,"Open link") }
                    IconButton(onClick = close) { Icon(Icons.Outlined.Close,"Close") }
                }
                HorizontalDivider()
                LazyColumn(Modifier.weight(1f).fillMaxWidth(),contentPadding = PaddingValues(16.dp),verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    item {
                        if (clip.isImage) StreamSensitive(strongBlur = true) { FullClipboardImage(clip) }
                        else StreamSensitive { SelectionContainer { Text(clip.text,style = MaterialTheme.typography.bodyLarge) } }
                    }
                    item {
                        val details = if (clip.isImage) "${clip.mime?.substringAfter('/')?.uppercase() ?: "IMAGE"} · ${clip.width} × ${clip.height} · ${android.text.format.Formatter.formatFileSize(context,clip.size)}" else "${clip.text.length} characters"
                        Text(details,style = MaterialTheme.typography.labelMedium,color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                HorizontalDivider()
                Column(Modifier.fillMaxWidth().padding(12.dp),verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(Modifier.fillMaxWidth(),horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { engine.copyClip(clip.id) },modifier = Modifier.weight(1f).height(46.dp),shape = RoundedCornerShape(11.dp)) {
                            Icon(Icons.Outlined.ContentCopy,null,modifier = Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Copy")
                        }
                        SyncOutlinedButton(onClick = { engine.toggleClipboardPin(clip.id) },modifier = Modifier.weight(1f).height(46.dp)) {
                            Icon(Icons.Outlined.PushPin,null,modifier = Modifier.size(18.dp)); Spacer(Modifier.width(5.dp)); Text(if (clip.pinned) "Unpin" else "Pin")
                        }
                    }
                    Row(Modifier.fillMaxWidth(),horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        SyncOutlinedButton(onClick = { engine.deleteClipboardClip(clip.id,false); close() },modifier = Modifier.weight(1f).height(46.dp),colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                            Icon(Icons.Outlined.Delete,null,modifier = Modifier.size(18.dp)); Spacer(Modifier.width(5.dp)); Text("Delete")
                        }
                        SyncOutlinedButton(onClick = { engine.deleteClipboardClip(clip.id,true); close() },modifier = Modifier.weight(1f).height(46.dp),colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                            Icon(Icons.Outlined.DeleteForever,null,modifier = Modifier.size(18.dp)); Spacer(Modifier.width(5.dp)); Text("Delete all")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FullClipboardImage(clip: ClipboardClip) {
    val image by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null,clip.imagePath) {
        value = withContext(Dispatchers.IO) { clip.imagePath?.let(BitmapFactory::decodeFile)?.asImageBitmap() }
    }
    val ratio = if (clip.width > 0 && clip.height > 0) clip.width.toFloat() / clip.height else 1f
    Surface(shape = RoundedCornerShape(12.dp),color = MaterialTheme.colorScheme.surfaceContainer,modifier = Modifier.fillMaxWidth()) {
        if (image != null) Image(image!!,"Full clipboard image",modifier = Modifier.fillMaxWidth().aspectRatio(ratio.coerceIn(.15f,5f)),contentScale = ContentScale.Fit)
        else Box(Modifier.fillMaxWidth().height(240.dp),contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    }
}

@Composable
private fun CompactClipboardImage(path: String?) {
    val image by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, path) {
        value = withContext(Dispatchers.IO) { path?.let(BitmapFactory::decodeFile)?.asImageBitmap() }
    }
    Surface(shape = RoundedCornerShape(10.dp),color = MaterialTheme.colorScheme.surfaceContainer,modifier = Modifier.size(62.dp)) {
        if (image != null) Image(image!!,"Clipboard image",modifier = Modifier.fillMaxSize(),contentScale = ContentScale.Crop)
        else Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.Image,null,tint = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun ClipboardDeviceChip(selected: Boolean,label: String,icon: ImageVector,onClick: () -> Unit) {
    FilterChip(selected = selected,onClick = onClick,label = { Text(label,maxLines = 1) },leadingIcon = { Icon(icon,null,modifier = Modifier.size(17.dp)) },shape = RoundedCornerShape(10.dp),border = FilterChipDefaults.filterChipBorder(enabled = true,selected = selected,borderColor = MaterialTheme.colorScheme.outlineVariant,selectedBorderColor = MaterialTheme.colorScheme.primary))
}

private fun clipboardDayLabel(timestamp: Long): String {
    val now = java.util.Calendar.getInstance()
    val value = java.util.Calendar.getInstance().apply { timeInMillis = timestamp }
    fun sameDay(left: java.util.Calendar,right: java.util.Calendar) = left.get(java.util.Calendar.ERA) == right.get(java.util.Calendar.ERA) && left.get(java.util.Calendar.YEAR) == right.get(java.util.Calendar.YEAR) && left.get(java.util.Calendar.DAY_OF_YEAR) == right.get(java.util.Calendar.DAY_OF_YEAR)
    if (sameDay(now,value)) return "Today"
    now.add(java.util.Calendar.DAY_OF_YEAR,-1)
    if (sameDay(now,value)) return "Yesterday"
    return java.text.SimpleDateFormat("MMM d, yyyy",java.util.Locale.getDefault()).format(java.util.Date(timestamp))
}

@Composable
private fun SetupScreen(state: EngineState, engine: SyncEngine, modifier: Modifier, openNotificationAccess: () -> Unit, requestOwnNotifications: () -> Unit, openPower: () -> Unit, requestMessages: () -> Unit, requestCalls: () -> Unit, exportDiagnostics: () -> Unit) {
    val required = listOf(!state.clipboardPaused, state.notificationAccess && state.postingNotifications, state.enabled && state.batteryUnrestricted && state.backgroundSetupConfirmed).count { it }
    val capabilities = DeviceCapabilities.detect(LocalContext.current, state)
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(colors = CardDefaults.cardColors(containerColor = if (required == 3) MaterialTheme.colorScheme.tertiary.copy(alpha = .10f) else MaterialTheme.colorScheme.primaryContainer)) {
                Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (required == 3) Icons.Outlined.VerifiedUser else Icons.Outlined.PendingActions, null, tint = if (required == 3) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.primary, modifier = Modifier.size(42.dp))
                    Column(Modifier.padding(start = 16.dp)) { Text(if (required == 3) "Ready for supported sync" else "Setup needs attention", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold); Text("$required of 3 required steps complete", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
        }
        item { SectionLabel("Required") }
        item { SettingRow(Icons.Outlined.ContentPaste, "Clipboard capture", if (state.clipboardPaused) "Clipboard sync is paused" else "Automatic while open · Share or notification action elsewhere", !state.clipboardPaused) { engine.enableClipboardSync() } }
        item { SettingRow(Icons.Outlined.NotificationsActive, "Notifications and replies", when { !state.notificationAccess -> "Notification listener access is off"; !state.postingNotifications -> "Allow Android Sync’s own alerts"; !state.listenerConnected -> "Listener reconnecting"; else -> "Mirroring and supported replies are active" }, state.notificationAccess && state.postingNotifications) { if (!state.notificationAccess) openNotificationAccess() else requestOwnNotifications() } }
        item { SettingRow(Icons.Outlined.BatterySaver, "Keep device connections active", if (state.enabled && state.batteryUnrestricted && state.backgroundSetupConfirmed) "Notifications, replies, and transfers can run in background" else "Complete ${DeviceCapabilities.powerGuide(engine.context).vendor} battery settings", state.enabled && state.batteryUnrestricted && state.backgroundSetupConfirmed) { openPower() } }
        item { SectionLabel("Optional") }
        item {
            ToggleSetting(Icons.Outlined.FolderCopy, "File transfer", "Choose and receive files securely", state.fileTransferEnabled, engine::setFileTransferEnabled)
        }
        if (BuildConfig.LOCAL_FULL) item {
            SettingRow(Icons.Outlined.FolderOpen, "Browse shared storage from Mac", if (state.allFilesAccess) "Shared folders are available; app-private folders stay excluded" else "Optional All files access is required", state.allFilesAccess) { engine.openAllFilesSettings() }
        }
        if (BuildConfig.LOCAL_FULL) item {
            SettingRow(Icons.Outlined.Sms, "Carrier SMS and contacts", if (state.messagePermissions) "Permissions granted; enable access separately for each Mac" else "Optional SMS and Contacts permissions", state.messagePermissions, requestMessages)
        }
        if (BuildConfig.LOCAL_FULL) item {
            val missing = listOf(
                Manifest.permission.READ_CALL_LOG to "Call logs",
                Manifest.permission.CALL_PHONE to "Place calls",
                Manifest.permission.ANSWER_PHONE_CALLS to "Answer calls"
            ).filter { (permission, _) -> engine.context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED }
            SettingRow(Icons.Outlined.Call, "Cellular calls, history & dialing", if (missing.isEmpty()) "All three Android phone permissions granted" else "Tap to allow: ${missing.joinToString { it.second }}", missing.isEmpty(), requestCalls)
        }
        item { SettingRow(Icons.Outlined.ScreenShare, "Screen mirroring", "Android shows a fresh system consent prompt for every session", true) {} }
        if (BuildConfig.LOCAL_FULL) item {
            SettingRow(Icons.Outlined.TouchApp, "Remote control", if (state.accessibilityControl) "Accessibility active; grant control separately to each Mac" else "Optional Accessibility service for taps, swipes, navigation, and text", state.accessibilityControl) { engine.openAccessibilitySettings() }
        }
        item { SettingRow(Icons.Outlined.PhoneInTalk, "Other app call notifications", if (state.notificationAccess) "Only actions exposed by a live notification" else "Requires notification access", state.notificationAccess) { openNotificationAccess() } }
        item { ToggleSetting(Icons.Outlined.PhoneDisabled, "Call audio on Mac", "Audio stays on the Android phone", false, {}, enabled = false, badge = "Not supported") }
        item { SectionLabel("Device capabilities") }
        items(capabilities.values, key = { it.id }) { capability ->
            val ready = capability.status == CapabilityStatus.ENABLED
            SettingRow(Icons.Outlined.Extension, capability.label, capability.reason, ready) {}
        }
        item { SectionLabel("Preferences") }
        item { ToggleSetting(Icons.Outlined.VisibilityOff, "Blur Sensitive Information (Stream Mode)", "Blur clipboard, images, file names, device identifiers, and pairing details while recording. Tap an item or hover with a mouse to reveal only that item.", state.streamModeEnabled, engine::setStreamModeEnabled) }
        item { SettingRow(Icons.Outlined.History, "Clipboard history", "Encrypted local history", true) { engine.clearClipboardHistory() } }
        item { SettingRow(Icons.Outlined.Security, "Clipboard privacy", "Sensitive content is excluded", true) {} }
        item { SettingRow(Icons.Outlined.Wifi, "Connection", "Local Wi-Fi · ${state.connections.values.count { it == "Connected" }} Macs", state.enabled) { engine.setEnabled(!state.enabled) } }
        item {
            SyncOutlinedButton(onClick = { engine.setOnboardingComplete(false) }, modifier = Modifier.fillMaxWidth()) { Text("Review permission setup") }
            Spacer(Modifier.height(8.dp))
            SyncOutlinedButton(onClick = { engine.refreshNotifications() }, modifier = Modifier.fillMaxWidth()) { Text("Refresh notification connection") }
            Spacer(Modifier.height(8.dp))
            SyncOutlinedButton(onClick = exportDiagnostics, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.BugReport, null); Spacer(Modifier.width(8.dp)); Text("Export redacted diagnostics") }
        }
        item { Text("Android Sync ${BuildConfig.VERSION_NAME} · ${android.os.Build.MODEL}\nAndroid ${android.os.Build.VERSION.RELEASE}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun SectionLabel(text: String) { Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant) }

@Composable
private fun SettingRow(icon: ImageVector, title: String, detail: String, complete: Boolean, action: () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow), modifier = Modifier.fillMaxWidth().clickable(onClick = action)) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(28.dp))
            Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text(title, fontWeight = FontWeight.SemiBold); Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Icon(if (complete) Icons.Outlined.CheckCircle else Icons.Outlined.ChevronRight, null, tint = if (complete) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ToggleSetting(icon: ImageVector, title: String, detail: String, checked: Boolean, change: (Boolean) -> Unit, enabled: Boolean = true, badge: String? = null) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(28.dp))
            Column(Modifier.weight(1f).padding(horizontal = 14.dp)) { Text(title, fontWeight = FontWeight.SemiBold); Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant); if (badge != null) Text(badge, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.error) }
            Switch(checked, change, enabled = enabled)
        }
    }
}

@Composable
fun InfoCard(icon: ImageVector, title: String, text: String) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.fillMaxWidth().padding(22.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(32.dp)); Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold); Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun ManualPairDialog(engine: SyncEngine, dismiss: () -> Unit) {
    var invitation by remember { mutableStateOf("") }
    var host by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = dismiss, title = { Text("Pair your Mac") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Paste the full invitation from the Mac’s Devices page.")
            StreamSensitive(Modifier.fillMaxWidth()) { OutlinedTextField(invitation, { invitation = it }, label = { Text("Invitation JSON") }, maxLines = 5, modifier = Modifier.fillMaxWidth()) }
            StreamSensitive(Modifier.fillMaxWidth()) { OutlinedTextField(host, { host = it }, label = { Text("Mac local address · optional") }, singleLine = true, modifier = Modifier.fillMaxWidth()) }
        }
    }, confirmButton = { TextButton(onClick = { engine.pair(invitation, host); dismiss() }, enabled = invitation.isNotBlank()) { Text("Pair") } }, dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}

@Composable
private fun ShareTextDialog(state: EngineState, shared: SharedIntent, shareAll: () -> Unit, shareOne: (String) -> Unit, dismiss: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, title = { Text("Share clipboard item") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            StreamSensitive { Text(shared.text.orEmpty(), maxLines = 5, overflow = TextOverflow.Ellipsis) }
            if (shared.sourceApp != null) StreamSensitive { Text("From ${shared.sourceApp}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Button(onClick = shareAll, modifier = Modifier.fillMaxWidth()) {
                Text(if (state.connections.values.any { it == "Connected" }) "Save and share with connected Macs" else "Save to clipboard history")
            }
            state.peers.filter { state.connections[it.id] == "Connected" }.forEach { peer -> SyncOutlinedButton(onClick = { shareOne(peer.id) }, modifier = Modifier.fillMaxWidth()) { Text(peer.name) } }
        }
    }, confirmButton = {}, dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}
