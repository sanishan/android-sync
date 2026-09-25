package dev.androidsync

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

private val terminalTransferStates = setOf("Completed", "Cancelled", "Declined")
private enum class FileTransferFilter(val label: String) { All("All"), Sent("Sent"), Received("Received") }

@Composable
fun FileSharingPage(engine: SyncEngine,state: EngineState,modifier: Modifier = Modifier,selectedMac: String?,selectMac: (String?) -> Unit,choose: () -> Unit) {
    var devicesOpen by remember { mutableStateOf(false) }
    var transferFilter by remember { mutableStateOf(FileTransferFilter.All) }
    val connectedPeers = state.peers.filter { state.connections[it.id] == "Connected" }
    val target = connectedPeers.firstOrNull { it.id == selectedMac } ?: connectedPeers.firstOrNull()
    val filteredTransfers = state.transfers.filter { transfer ->
        when (transferFilter) {
            FileTransferFilter.All -> true
            FileTransferFilter.Sent -> !transfer.incoming
            FileTransferFilter.Received -> transfer.incoming
        }
    }
    val active = filteredTransfers.filter { it.status !in terminalTransferStates }
    val recent = filteredTransfers.filter { it.status in terminalTransferStates }
    LaunchedEffect(connectedPeers.map { it.id },selectedMac) { if (target?.id != selectedMac) selectMac(target?.id) }
    LazyColumn(modifier.fillMaxSize(),contentPadding = PaddingValues(SyncPagePadding),verticalArrangement = Arrangement.spacedBy(SyncItemSpacing)) {
        item {
            SyncCard {
                Row(Modifier.fillMaxWidth().clickable(enabled = connectedPeers.isNotEmpty()) { devicesOpen = true }.padding(horizontal = 12.dp,vertical = 10.dp),verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.DesktopMac,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(24.dp))
                    Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                        Text("Send to",style = MaterialTheme.typography.labelMedium,color = MaterialTheme.colorScheme.onSurfaceVariant)
                        StreamSensitive { Text(target?.name ?: "No Mac connected",fontWeight = FontWeight.SemiBold,style = MaterialTheme.typography.bodyLarge,maxLines = 1,overflow = TextOverflow.Ellipsis) }
                    }
                    if (target != null) {
                        Surface(shape = androidx.compose.foundation.shape.CircleShape,color = MaterialTheme.colorScheme.tertiary,modifier = Modifier.size(8.dp)) {}
                        Text("Connected",style = MaterialTheme.typography.labelMedium,color = MaterialTheme.colorScheme.tertiary,modifier = Modifier.padding(horizontal = 7.dp))
                    }
                    Icon(Icons.Outlined.ExpandMore,null)
                    DropdownMenu(expanded = devicesOpen,onDismissRequest = { devicesOpen = false }) {
                        connectedPeers.forEach { peer -> DropdownMenuItem(text = { Text(peer.name) },onClick = { selectMac(peer.id); devicesOpen = false },leadingIcon = { Icon(Icons.Outlined.DesktopMac,null) },trailingIcon = { if (peer.id == target?.id) Icon(Icons.Outlined.Check,null,tint = MaterialTheme.colorScheme.primary) }) }
                    }
                }
            }
        }
        item {
            Button(onClick = choose,enabled = state.fileTransferEnabled && !state.preparing && target != null,modifier = Modifier.fillMaxWidth().height(48.dp),shape = SyncCardShape) {
                Icon(Icons.Outlined.NoteAdd,null,modifier = Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text("Choose files")
            }
            Text("Select up to 100 files",style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.onSurfaceVariant,modifier = Modifier.fillMaxWidth().padding(top = 4.dp),textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
        item {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                FileTransferFilter.entries.forEachIndexed { index, option ->
                    SegmentedButton(
                        selected = transferFilter == option,
                        onClick = { transferFilter = option },
                        shape = SegmentedButtonDefaults.itemShape(index = index,count = FileTransferFilter.entries.size),
                        label = { Text(option.label) }
                    )
                }
            }
        }
        if (!state.fileTransferEnabled) item { CompactFileNotice("File transfer is off. Enable it in Settings.") }
        if (state.preparing) item {
            SyncCard {
                Column(Modifier.fillMaxWidth().padding(12.dp),verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Text("Preparing files and verifying integrity…",style = MaterialTheme.typography.bodySmall)
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth(),color = MaterialTheme.colorScheme.secondary,trackColor = MaterialTheme.colorScheme.background)
                }
            }
        }
        if (active.isNotEmpty()) {
            item { FileSectionLabel("Active") }
            items(active,key = { it.offer.id }) { transfer -> TransferCard(transfer,engine) }
        }
        item { FileSectionLabel("Recent") }
        if (recent.isEmpty()) item {
            CompactFileNotice(
                when {
                    filteredTransfers.isNotEmpty() -> "Completed and cancelled transfers appear here."
                    transferFilter == FileTransferFilter.Sent -> "No sent transfers yet."
                    transferFilter == FileTransferFilter.Received -> "No received transfers yet."
                    else -> "No transfers yet · Received files save to Downloads / Android Sync"
                }
            )
        }
        items(recent,key = { it.offer.id }) { transfer -> TransferCard(transfer,engine) }
    }
}

@Composable
fun TransferCard(transfer: TransferState, engine: SyncEngine) {
    val context = LocalContext.current
    var expanded by remember { mutableStateOf(false) }
    val complete = transfer.status == "Completed"
    val fraction = if (complete) 1f else (transfer.bytes.toFloat() / transfer.total.coerceAtLeast(1)).coerceIn(0f, 1f)
    val finished = transfer.status in terminalTransferStates
    val waitingForDecision = transfer.incoming && !transfer.accepted && transfer.status == "Awaiting your acceptance"
    val resumable = transfer.status.startsWith("Interrupted") || transfer.status.startsWith("Failed")
    val showProgress = !finished && !resumable
    val peer = engine.state.value.peers.firstOrNull { it.id == transfer.macId }?.name ?: "Mac"
    SyncCard {
        Column(Modifier.fillMaxWidth().padding(12.dp),verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(shape = RoundedCornerShape(10.dp),color = MaterialTheme.colorScheme.primaryContainer,modifier = Modifier.size(42.dp)) {
                    Box(contentAlignment = Alignment.Center) { Icon(if (transfer.incoming) Icons.Outlined.Download else Icons.Outlined.Upload,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(22.dp)) }
                }
                Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                    StreamSensitive { Text(transfer.offer.files.first().name + if (transfer.offer.files.size > 1) " +${transfer.offer.files.size - 1} more" else "",fontWeight = FontWeight.SemiBold,style = MaterialTheme.typography.bodyMedium,maxLines = 1,overflow = TextOverflow.Ellipsis) }
                    Text("${if (transfer.incoming) "From" else "To"} $peer · ${transfer.offer.files.size} ${if (transfer.offer.files.size == 1) "file" else "files"}",style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant,maxLines = 1,overflow = TextOverflow.Ellipsis)
                    if (transfer.offer.transport == "plain-binary") Text("Insecure Wi-Fi · unencrypted",style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.error)
                    else if (transfer.offer.transport == "tls-binary") Text("Encrypted Wi-Fi",style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.tertiary)
                }
                if (showProgress) Text("${(fraction * 100).toInt()}%",style = MaterialTheme.typography.titleSmall,fontWeight = FontWeight.Bold)
                else Text(transfer.status,style = MaterialTheme.typography.labelMedium,color = if (complete) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant)
                if (transfer.offer.files.size > 1) IconButton(onClick = { expanded = !expanded },modifier = Modifier.size(36.dp)) { Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,"File details") }
            }
            if (showProgress) {
                LinearProgressIndicator(
                    progress = { fraction },
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.secondary,
                    trackColor = MaterialTheme.colorScheme.background
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (finished) "${Formatter.formatFileSize(context,transfer.total)} · ${transfer.status}" else "${transfer.completed.size} of ${transfer.offer.files.size} · ${Formatter.formatFileSize(context,transfer.bytes)} of ${Formatter.formatFileSize(context,transfer.total)}",style = MaterialTheme.typography.labelSmall,color = if (complete) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant,modifier = Modifier.weight(1f))
                if (!finished && transfer.speedBytesPerSecond > 0) Text("${Formatter.formatFileSize(context,transfer.speedBytesPerSecond)}/s",style = MaterialTheme.typography.labelSmall,color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (expanded) {
                transfer.offer.files.take(8).forEach { file ->
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.Outlined.InsertDriveFile,null,modifier = Modifier.size(18.dp),tint = MaterialTheme.colorScheme.primary)
                        StreamSensitive(Modifier.weight(1f).padding(horizontal = 8.dp)) { Text(file.name,style = MaterialTheme.typography.bodySmall,maxLines = 1,overflow = TextOverflow.Ellipsis) }
                        Text(Formatter.formatFileSize(context,file.size),style = MaterialTheme.typography.labelSmall)
                        if (file.id in transfer.completed) Icon(Icons.Outlined.CheckCircle,null,tint = MaterialTheme.colorScheme.tertiary,modifier = Modifier.padding(start = 6.dp).size(16.dp))
                    }
                }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (waitingForDecision) {
                    Button(onClick = { engine.fileManager.acceptIncoming(transfer.offer.id) }) {
                        Icon(Icons.Outlined.Download,null,modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Accept")
                    }
                    SyncOutlinedButton(
                        onClick = { engine.fileManager.decline(transfer.offer.id) },
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
                    ) {
                        Icon(Icons.Outlined.Block,null,modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Decline")
                    }
                }
                if (resumable) SyncOutlinedButton(onClick = { engine.fileManager.resume(transfer.offer.id) }) {
                    Icon(Icons.Outlined.Refresh,null,modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Resume")
                }
                if (!finished && !waitingForDecision) SyncOutlinedButton(
                    onClick = { engine.fileManager.cancel(transfer.offer.id) },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Icon(Icons.Outlined.Cancel,null,modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Cancel")
                }
                transfer.saved.values.firstOrNull()?.let { saved ->
                    TextButton(onClick = { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(saved)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)) } }) { Text("Open received file") }
                }
            }
        }
    }
}

@Composable
private fun FileSectionLabel(text: String) { Text(text,style = MaterialTheme.typography.titleSmall,fontWeight = FontWeight.Bold,color = MaterialTheme.colorScheme.onSurfaceVariant,modifier = Modifier.padding(top = 2.dp,start = 2.dp)) }

@Composable
private fun CompactFileNotice(text: String) {
    SyncCard { Row(Modifier.fillMaxWidth().padding(12.dp),verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Outlined.Info,null,tint = MaterialTheme.colorScheme.primary,modifier = Modifier.size(20.dp)); Text(text,modifier = Modifier.padding(start = 9.dp),style = MaterialTheme.typography.bodySmall,color = MaterialTheme.colorScheme.onSurfaceVariant) } }
}

private data class SelectedFileInfo(val uri: Uri, val name: String, val size: Long)

@Composable
fun FileBatchReviewDialog(
    engine: SyncEngine,
    state: EngineState,
    selection: List<Uri>,
    initialMac: String?,
    addMore: () -> Unit,
    remove: (Uri) -> Unit,
    close: () -> Unit,
    sent: () -> Unit
) {
    val context = LocalContext.current
    var selectedMac by remember(state.peers,initialMac) { mutableStateOf(initialMac?.takeIf { state.connections[it] == "Connected" } ?: state.peers.firstOrNull { state.connections[it.id] == "Connected" }?.id) }
    val details = remember(selection) {
        selection.map { uri ->
            var name = uri.lastPathSegment ?: "File"
            var size = 0L
            runCatching {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = cursor.getString(it) ?: name }
                        cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }?.let { if (!cursor.isNull(it)) size = cursor.getLong(it) }
                    }
                }
            }
            SelectedFileInfo(uri, name, size)
        }
    }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().systemBarsPadding()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = close) { Icon(Icons.Outlined.ArrowBack, "Back") }
                    Text("Send files", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                }
                LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    item { Text("Send to", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            state.peers.filter { state.connections[it.id] == "Connected" }.forEach { peer ->
                                FilterChip(selectedMac == peer.id, { selectedMac = peer.id }, { Text(peer.name) }, leadingIcon = { Icon(Icons.Outlined.DesktopMac, null, modifier = Modifier.size(18.dp)) })
                            }
                        }
                    }
                    item {
                        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                            Row(Modifier.fillMaxWidth().padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Outlined.FolderCopy, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(36.dp))
                                Column(Modifier.padding(start = 14.dp)) {
                                    Text("${details.size} ${if (details.size == 1) "file" else "files"} · ${Formatter.formatFileSize(context, details.sumOf { it.size })}", fontWeight = FontWeight.Bold)
                                    StreamSensitive { Text("${state.peers.firstOrNull { it.id == selectedMac }?.name ?: "The Mac"} will receive this trusted batch automatically unless Ask every time is enabled there", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                }
                            }
                        }
                    }
                    item { Text("Selected files", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold) }
                    items(details, key = { it.uri }) { file ->
                        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                            Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Outlined.InsertDriveFile, null, tint = MaterialTheme.colorScheme.primary)
                                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) { StreamSensitive { Text(file.name, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis) }; Text(Formatter.formatFileSize(context, file.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                IconButton(onClick = { remove(file.uri) }) { Icon(Icons.Outlined.Close, "Remove", tint = MaterialTheme.colorScheme.error) }
                            }
                        }
                    }
                    item { SyncOutlinedButton(onClick = addMore, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text("Add more") } }
                }
                Surface(shadowElevation = 8.dp) {
                    Button(onClick = { selectedMac?.let { engine.fileManager.prepare(selection, it); sent() } }, enabled = selectedMac != null && selection.isNotEmpty() && !state.preparing, modifier = Modifier.fillMaxWidth().padding(20.dp).height(54.dp)) {
                        Text("Send ${selection.size} ${if (selection.size == 1) "file" else "files"}")
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IncomingTransferSheet(transfer: TransferState, peerName: String, engine: SyncEngine, dismiss: () -> Unit) {
    val context = LocalContext.current
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 22.dp).padding(bottom = 30.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.LaptopMac, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(52.dp))
            AssistChip(onClick = {}, label = { Text("Protected") }, leadingIcon = { Icon(Icons.Outlined.Lock, null, modifier = Modifier.size(17.dp)) })
            StreamSensitive { Text("$peerName wants to send files", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold) }
            Text("${transfer.offer.files.size} files · ${Formatter.formatFileSize(context, transfer.total)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow), modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    transfer.offer.files.take(3).forEach { StreamSensitive { Text(it.name, maxLines = 1, overflow = TextOverflow.Ellipsis) } }
                    if (transfer.offer.files.size > 3) Text("+ ${transfer.offer.files.size - 3} more", color = MaterialTheme.colorScheme.primary)
                }
            }
            Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) { Text("Save to", fontWeight = FontWeight.SemiBold); Icon(Icons.Outlined.Folder, null, modifier = Modifier.padding(start = 14.dp)); Text("Downloads / Android Sync", modifier = Modifier.padding(start = 8.dp)) }
            }
            Text("Transfer begins only after you accept.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = { engine.fileManager.acceptIncoming(transfer.offer.id) }, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text("Accept and receive") }
            SyncOutlinedButton(onClick = { engine.fileManager.decline(transfer.offer.id) }, modifier = Modifier.fillMaxWidth().height(50.dp), colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Decline") }
        }
    }
}
