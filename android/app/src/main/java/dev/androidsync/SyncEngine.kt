package dev.androidsync

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.Manifest
import android.content.ComponentName
import android.content.IntentSender
import android.content.pm.PackageManager
import android.companion.AssociationRequest
import android.companion.CompanionDeviceManager
import android.companion.WifiDeviceFilter
import android.service.notification.NotificationListenerService
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

const val DEFAULT_CLIPBOARD_QUOTA = 1024L * 1024L * 1024L

class SyncApplication : android.app.Application() {
    lateinit var engine: SyncEngine
    override fun onCreate() { super.onCreate(); engine = SyncEngine(this) }
}
fun Context.engine(): SyncEngine = (applicationContext as SyncApplication).engine

data class TransferState(val offer: FileOffer, val macId: String, val incoming: Boolean, val status: String, val accepted: Boolean = false, val sources: Map<String,String> = emptyMap(), val completed: Set<String> = emptySet(), val saved: Map<String,String> = emptyMap(), val bytes: Long = 0, val speedBytesPerSecond: Long = 0, val startedAt: Long = 0) {
    val total get() = offer.files.sumOf { it.size }
    fun json() = obj("offer" to offer.json(),"macId" to macId,"incoming" to incoming,"status" to status,"accepted" to accepted,"sources" to JSONObject(sources),"completed" to array(completed),"saved" to JSONObject(saved),"bytes" to bytes,"speedBytesPerSecond" to speedBytesPerSecond,"startedAt" to startedAt)
    companion object {
        fun parse(o: JSONObject): TransferState {
            fun map(key: String): Map<String,String> { val value = o.optJSONObject(key) ?: JSONObject(); return value.keys().asSequence().associateWith { value.getString(it) } }
            val done = o.optJSONArray("completed") ?: JSONArray()
            return TransferState(FileOffer.parse(o.getJSONObject("offer")),o.getString("macId"),o.getBoolean("incoming"),o.getString("status"),o.optBoolean("accepted"),map("sources"),(0 until done.length()).map { done.getString(it) }.toSet(),map("saved"),o.optLong("bytes"),o.optLong("speedBytesPerSecond"),o.optLong("startedAt"))
        }
    }
}
data class EngineState(
    val peers: List<MacPeer> = emptyList(), val connections: Map<String,String> = emptyMap(), val enabled: Boolean = false,
    val clipboardPaused: Boolean = false, val pausedClipboardDevices: Set<String> = emptySet(),
    val notificationAccess: Boolean = false, val listenerConnected: Boolean = false, val postingNotifications: Boolean = false,
    val batteryUnrestricted: Boolean = false, val backgroundSetupConfirmed: Boolean = false,
    val onboardingComplete: Boolean = false, val fileTransferEnabled: Boolean = true, val allFilesAccess: Boolean = false,
    val streamModeEnabled: Boolean = false,
    val askEveryTimeFiles: Set<String> = emptySet(), val messageDevices: Set<String> = emptySet(), val messagePermissions: Boolean = false,
    val screenDevices: Set<String> = emptySet(), val controlDevices: Set<String> = emptySet(),
    val accessibilityControl: Boolean = false,
    val companionAssociated: Boolean = false,
    val latestText: String = "", val origin: String = "Nothing shared yet", val transfers: List<TransferState> = emptyList(),
    val clipboardClips: List<ClipboardClip> = emptyList(), val clipboardQuotaBytes: Long = DEFAULT_CLIPBOARD_QUOTA, val links: List<String> = emptyList(),
    val pairing: Boolean = false, val preparing: Boolean = false, val error: String? = null
)
class SyncEngine(val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val store = SecureStore(context)
    private val mutable = MutableStateFlow(EngineState())
    val state = mutable.asStateFlow()
    val connections = ConcurrentHashMap<String,MacConnection>()
    private val connectionJobs = ConcurrentHashMap<String,Job>()
    private val pairingConnections = ConcurrentHashMap<String,MacConnection>()
    val discovery = Discovery(context) {}
    val fileManager = TransferManager(this)
    val sharedStorage = SharedStorageBrowser(this)
    val gallery = GalleryBrowser(this)
    val messages = createMessageSyncModule(this)
    val remoteControl = createRemoteControlModule(this)
    val screenMirror = ScreenMirrorCoordinator(this)
    val clipboardHistoryStore = ClipboardHistoryStore(this)
    val clipboardImages = ClipboardImageSync(this)
    private val seen = SeenEvents()
    private val clipboardTombstones = LinkedHashSet<String>()
    private val logicalClock = LogicalClock()
    private val clipboardSession = UUID.randomUUID().toString()
    private var revision = 0L
    private var lastText: String? = null
    private var ownClipboardSignature: String? = null
    private var recentSourcePackage: String? = null
    private var recentSourceAt = 0L
    @Volatile var foreground = false
    val clipboard = context.getSystemService(ClipboardManager::class.java)
    private val foregroundClipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (foreground) inspectForegroundClipboard()
    }
    init {
        runCatching {
            val peers = JSONArray(store.get("peers") ?: "[]")
            val transfers = JSONArray(store.get("transfers") ?: "[]")
            val quota = store.get("clipboard-quota")?.toLongOrNull()?.coerceIn(64L * 1024 * 1024,4L * 1024 * 1024 * 1024) ?: DEFAULT_CLIPBOARD_QUOTA
            val tombstones = JSONArray(store.get("clipboard-tombstones") ?: "[]")
            val pausedDevicesJson = JSONArray(store.get("clipboard-paused-devices") ?: "[]")
            val askFilesJson = JSONArray(store.get("file-ask-every-time") ?: "[]")
            val messageDevicesJson = JSONArray(store.get("message-devices") ?: "[]")
            val screenDevicesJson = JSONArray(store.get("screen-devices") ?: "[]")
            val controlDevicesJson = JSONArray(store.get("control-devices") ?: "[]")
            (0 until tombstones.length()).mapTo(clipboardTombstones) { tombstones.getString(it) }
            val loadedClipboard = clipboardHistoryStore.load()
            val (activeClipboard,expiredClipboard) = ClipboardQuota.retain(loadedClipboard.filterNot { clipboardTombstones.contains(it.id) },quota)
            (loadedClipboard.filter { clipboardTombstones.contains(it.id) } + expiredClipboard).distinctBy { it.id }.forEach {
                clipboardImages.delete(it); clipboardHistoryStore.deleteArchive(it)
            }
            clipboardHistoryStore.save(activeClipboard)
            activeClipboard.maxOfOrNull { it.logicalClock }?.takeIf { it > 0 }?.let(logicalClock::observe)
            mutable.value = EngineState(
                peers = (0 until peers.length()).map { MacPeer.parse(peers.getJSONObject(it)) },
                transfers = (0 until transfers.length()).map { TransferState.parse(transfers.getJSONObject(it)) },
                clipboardClips = activeClipboard,
                clipboardQuotaBytes = quota,
                pausedClipboardDevices = (0 until pausedDevicesJson.length()).map { pausedDevicesJson.getString(it) }.toSet(),
                askEveryTimeFiles = (0 until askFilesJson.length()).map { askFilesJson.getString(it) }.toSet(),
                allFilesAccess = sharedStorage.available,
                messageDevices = (0 until messageDevicesJson.length()).map { messageDevicesJson.getString(it) }.toSet(),
                messagePermissions = messages.permissionsGranted,
                screenDevices = (0 until screenDevicesJson.length()).map { screenDevicesJson.getString(it) }.toSet(),
                controlDevices = (0 until controlDevicesJson.length()).map { controlDevicesJson.getString(it) }.toSet(),
                accessibilityControl = remoteControl.enabled,
                enabled = store.get("enabled") == "true", clipboardPaused = store.get("clipboard-paused") == "true",
                onboardingComplete = store.get("onboarding-complete") == "true",
                backgroundSetupConfirmed = store.get("background-setup-confirmed") == "true" || store.get("samsung-setup-confirmed") == "true",
                fileTransferEnabled = store.get("file-transfer-enabled") != "false",
                streamModeEnabled = store.get("stream-mode-enabled") == "true"
            )
            fileManager.cleanupTerminal()
        }.onFailure { fail("Encrypted settings could not be loaded. ${it.message ?: "Try reopening the app."}") }
        clipboard.addPrimaryClipChangedListener(foregroundClipboardListener)
        messages.refreshPermissionState()
        remoteControl.refresh()
        refreshPermissions()
    }
    fun refreshPermissions(rebind: Boolean = false) {
        val allowed = context.getSystemService(NotificationManager::class.java).isNotificationListenerAccessGranted(ComponentName(context,PhoneNotificationService::class.java))
        val bound = PhoneNotificationService.current != null
        val posting = Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val unrestricted = context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)
        messages.refreshPermissionState()
        remoteControl.refresh()
        val companion = context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP) && runCatching {
            context.getSystemService(CompanionDeviceManager::class.java).let { manager ->
                if (Build.VERSION.SDK_INT >= 33) manager.myAssociations.isNotEmpty() else @Suppress("DEPRECATION") manager.associations.isNotEmpty()
            }
        }.getOrDefault(false)
        mutable.update { it.copy(notificationAccess = allowed,listenerConnected = bound,postingNotifications = posting,batteryUnrestricted = unrestricted,allFilesAccess = sharedStorage.available,messagePermissions = messages.permissionsGranted,accessibilityControl = remoteControl.enabled,companionAssociated = companion) }
        if (rebind && allowed && !bound) runCatching { NotificationListenerService.requestRebind(ComponentName(context,PhoneNotificationService::class.java)) }
        reportPhoneStatus()
    }
    fun reportPhoneStatus(connection: MacConnection? = null) {
        if (connection == null) {
            connections.values.forEach { reportPhoneStatus(it) }
            return
        }
        val capabilities = DeviceCapabilities.detect(context,state.value).values.map { capability ->
            obj("id" to capability.id,"state" to capability.status.name.lowercase(),"reason" to capability.reason)
        }
        val message = Wire("phone.status",obj(
            "notificationAccess" to state.value.notificationAccess,
            "listenerConnected" to state.value.listenerConnected,
            "clipboardMode" to "foreground_with_user_actions",
            "clipboardPaused" to state.value.clipboardPaused,
            "messagesAccess" to state.value.messageDevices.contains(connection.peer.id),
            "messagesPermissions" to state.value.messagePermissions,
            "protocol" to 2,
            "lanes" to array(listOf("control","bulk","realtime")),
            "capabilitySet" to obj("capabilities" to array(capabilities))
        ),capability = "device")
        connection.enqueue(decorate(message))
    }
    fun refreshNotifications() {
        refreshPermissions(true)
        PhoneNotificationService.current?.let { service -> connections.values.forEach { service.snapshot(it) } }
    }
    fun postTestNotification() {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) { fail("Allow Android Sync notifications in Settings before sending a test alert."); return }
        manager.createNotificationChannel(NotificationChannel("sync-test","Notification sync test",NotificationManager.IMPORTANCE_DEFAULT))
        manager.notify(PhoneNotificationService.TEST_ID,Notification.Builder(context,"sync-test").setSmallIcon(R.drawable.ic_sync).setContentTitle("Android Sync test").setContentText("Notification mirroring is working on this Mac.").setAutoCancel(true).build())
    }
    @Synchronized fun updateForeground(value: Boolean) {
        foreground = value
        if (!value) recentSourcePackage = null
    }
    @Synchronized fun baselineClipboard() {
        val item = runCatching { clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) }.getOrNull()
        lastText = item?.text?.toString()
    }
    fun inspectForegroundClipboard() {
        if (!foreground || state.value.clipboardPaused || state.value.pausedClipboardDevices.contains(store.phoneId)) return
        runCatching {
            val clip = clipboard.primaryClip ?: return
            if (clip.itemCount == 0) return
            if (clip.description.extras?.getBoolean("android.content.extra.IS_SENSITIVE",false) == true) return
            val item = clip.getItemAt(0)
            val source = currentClipboardSource()
            val text = item.text?.toString()
            if (!text.isNullOrEmpty()) {
                if (text != lastText) {
                    lastText = text
                    coordinateClipboard(text,Build.MODEL,source?.app,source?.packageName)
                }
                markOwnClipboard("text:$text")
            }
            else item.uri?.let { uri ->
                if (uri.authority == "${context.packageName}.files") return@runCatching
                val mime = clip.description.filterMimeTypes("image/*")?.firstOrNull()
                    ?: context.contentResolver.getType(uri)
                if (mime?.startsWith("image/") == true && ownClipboardSignature != "image:$uri") {
                    markOwnClipboard("image:$uri")
                    clipboardImages.capture(uri,mime,source)
                }
            }
        }
    }
    fun fail(message: String) { mutable.update { it.copy(error = message) } }
    fun clearError() { mutable.update { it.copy(error = null) } }
    fun setEnabled(value: Boolean) { safeSave("enabled",value.toString()); mutable.update { it.copy(enabled = value) }; if (value) ConnectionService.start(context) else context.stopService(android.content.Intent(context,ConnectionService::class.java)) }
    @Synchronized fun startConnections() {
        discovery.start()
        state.value.peers.forEach { saved ->
            if (connectionJobs[saved.id]?.isActive == true) return@forEach
            connectionJobs[saved.id] = scope.launch {
                var attempts = 0
                while (isActive && state.value.enabled && state.value.peers.any { it.id == saved.id }) {
                    var connection: MacConnection? = null
                    try {
                        mutable.update { it.copy(connections = it.connections + (saved.id to "Connecting…")) }
                        connection = pairingConnections.remove(saved.id) ?: run {
                            val endpoint = discovery.endpoints[saved.id]
                            val current = state.value.peers.first { it.id == saved.id }
                            val candidates = (listOfNotNull(endpoint?.let { current.copy(host = it.first,port = it.second) }) + current).distinct()
                            var opened: MacConnection? = null; var failure: Exception? = null
                            for (candidate in candidates) { try { opened = MacConnection.open(candidate,store,"control"); break } catch (e: Exception) { failure = e } }
                            opened ?: throw failure ?: IllegalStateException("No local endpoint")
                        }
                        rememberLiveEndpoint(connection.peer)
                        connections[saved.id] = connection; attempts = 0
                        connection.startWriter(scope)
                        mutable.update { it.copy(connections = it.connections + (saved.id to "Connected")) }
                        refreshPermissions(); reportPhoneStatus(connection)
                        PhoneNotificationService.current?.snapshot(connection)
                        PhoneNotificationService.current?.mediaSnapshot(connection)
                        if (state.value.messageDevices.contains(saved.id)) { messages.snapshot(connection); messages.contacts(connection) }
                        clipboardTombstones.forEach { targetId -> connection.enqueue(decorate(Wire("clipboard.delete",obj("targetId" to targetId,"historical" to true),capability = "clipboard"))) }
                        restoreTransfers(connection)
                        val activeConnection = connection
                        val heartbeat = scope.launch {
                            while (isActive) { delay(10_000); refreshPermissions(); activeConnection.enqueue(Wire("ping")) }
                        }
                        try { while (isActive) receive(connection,connection.io.read()) } finally { heartbeat.cancel() }
                    } catch (e: Exception) {
                        if (isActive && state.value.enabled) mutable.update { it.copy(connections = it.connections + (saved.id to "Offline · ${connectionReason(e)}")) }
                    } finally {
                        connection?.close(); connection?.let { connections.remove(saved.id,it) }
                        fileManager.interruptMac(saved.id)
                    }
                    attempts++; delay((1000L shl attempts.coerceAtMost(4)).coerceAtMost(20_000))
                }
            }
        }
    }
    private fun connectionReason(e: Exception): String = when {
        e.message?.contains("identity") == true -> "identity changed; pair again"
        e is java.net.ConnectException -> "check Mac app and firewall"
        e is java.net.SocketTimeoutException -> "connection timed out"
        else -> "waiting to reconnect"
    }
    @Synchronized fun stopConnections() {
        connectionJobs.values.forEach { it.cancel() }; connectionJobs.clear(); connections.values.forEach { it.close() }; connections.clear()
        pairingConnections.values.forEach { it.close() }; pairingConnections.clear(); fileManager.interruptAll(); discovery.stop()
        mutable.update { it.copy(connections = emptyMap()) }; lastText = null
    }
    fun pair(text: String, manualHost: String = "") {
        mutable.update { it.copy(pairing = true) }
        scope.launch {
            try {
                val invitation = Invitation.parse(text)
                val endpoints = if (manualHost.isNotBlank()) listOf(manualHost) else (listOfNotNull(discovery.endpoints[invitation.peer.id]?.first) + invitation.hosts).distinct()
                require(endpoints.isNotEmpty()) { "Enter the Mac’s local address." }
                var connection: MacConnection? = null; var lastError: Exception? = null
                for (host in endpoints) {
                    try { connection = MacConnection.open(invitation.peer.copy(host = host),store,"control",invitation.secret); break } catch (e: Exception) { lastError = e }
                }
                val paired = connection ?: throw lastError ?: IllegalStateException("Cannot reach Mac")
                pairingConnections[paired.peer.id]?.close(); pairingConnections[paired.peer.id] = paired
                mutable.update { it.copy(peers = it.peers.filterNot { p -> p.id == paired.peer.id } + paired.peer) }; savePeers()
                connectionJobs.remove(paired.peer.id)?.cancel(); connections.remove(paired.peer.id)?.close()
                setEnabled(true); startConnections()
            } catch (e: Exception) { fail("Pairing failed: ${e.message}") }
            finally { mutable.update { it.copy(pairing = false) } }
        }
    }
    fun forget(id: String) {
        connections.remove(id)?.let { runCatching { it.io.send(Wire("device.unpair")) }; it.close() }; connectionJobs.remove(id)?.cancel()
        screenMirror.stop(id,null)
        val asks = state.value.askEveryTimeFiles - id; val messageDevices = state.value.messageDevices - id
        val screens = state.value.screenDevices - id; val controls = state.value.controlDevices - id
        mutable.update { it.copy(peers = it.peers.filterNot { p -> p.id == id },connections = it.connections - id,askEveryTimeFiles = asks,messageDevices = messageDevices,screenDevices = screens,controlDevices = controls) }
        safeSave("file-ask-every-time",array(asks).toString()); safeSave("message-devices",array(messageDevices).toString()); safeSave("screen-devices",array(screens).toString()); safeSave("control-devices",array(controls).toString()); savePeers(); fileManager.interruptMac(id)
    }
    fun updateEndpoint(id: String, host: String, port: Int) {
        if (port !in 1..65535 || host.isBlank()) { fail("Enter a local address and a port from 1 to 65535."); return }
        mutable.update { it.copy(peers = it.peers.map { p -> if (p.id == id) p.copy(host = host,port = port) else p }) }
        savePeers(); connections[id]?.close(); discovery.endpoints.remove(id)
    }
    fun peerForLane(id: String): MacPeer? = connections[id]?.peer ?: state.value.peers.firstOrNull { it.id == id }
    private fun rememberLiveEndpoint(peer: MacPeer) {
        val saved = state.value.peers.firstOrNull { it.id == peer.id } ?: return
        if (saved.host == peer.host && saved.port == peer.port) return
        mutable.update { current ->
            current.copy(peers = current.peers.map { value ->
                if (value.id == peer.id) value.copy(host = peer.host,port = peer.port) else value
            })
        }
        savePeers()
    }
    private fun savePeers() { safeSave("peers",array(state.value.peers.map { it.json() }).toString()) }
    fun requestCompanionAssociation(launchApproval: (IntentSender) -> Unit) {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)) { fail("This Android device does not provide Companion Device setup."); return }
        val request = AssociationRequest.Builder()
            .addDeviceFilter(WifiDeviceFilter.Builder().build())
            .setSingleDevice(false)
            .build()
        val manager = context.getSystemService(CompanionDeviceManager::class.java)
        val callback = object : CompanionDeviceManager.Callback() {
            @Deprecated("Android 12 callback")
            override fun onDeviceFound(intentSender: IntentSender) = launchApproval(intentSender)
            override fun onAssociationPending(intentSender: IntentSender) = launchApproval(intentSender)
            override fun onAssociationCreated(associationInfo: android.companion.AssociationInfo) { refreshPermissions(); reportPhoneStatus() }
            override fun onFailure(errorMessage: CharSequence?) { fail("Android companion association failed: ${errorMessage ?: "try again"}") }
        }
        if (Build.VERSION.SDK_INT >= 33) manager.associate(request,context.mainExecutor,callback)
        else @Suppress("DEPRECATION") manager.associate(request,callback,Handler(Looper.getMainLooper()))
    }
    fun safeSave(key: String, value: String) { runCatching { store.put(key,value) }.onFailure { fail("Could not save encrypted settings.") } }
    private fun capabilityFor(type: String): String? = when {
        type.startsWith("notification") || type.startsWith("notifications") || type == "action.result" -> "notifications"
        type.startsWith("clipboard") -> "clipboard"
        type.startsWith("file") || type.startsWith("storage") || type.startsWith("gallery") -> "files"
        type.startsWith("sms") -> "sms"
        type.startsWith("stream") || type.startsWith("control") -> "realtime"
        type.startsWith("media") -> "media"
        else -> null
    }
    internal fun decorate(wire: Wire): Wire = if (wire.version < 2 || wire.originDeviceId != null) wire else wire.copy(
        originDeviceId = store.phoneId,
        clock = logicalClock.tick(),
        capability = wire.capability ?: capabilityFor(wire.type)
    )
    fun send(macId: String, wire: Wire) { connections[macId]?.enqueue(decorate(wire)) }
    fun broadcast(wire: Wire) { val message = decorate(wire); connections.keys.forEach { connections[it]?.enqueue(message) } }
    private fun receive(connection: MacConnection, wire: Wire) {
        wire.clock?.let(logicalClock::observe)
        if (wire.type == "pong") return
        if (wire.type == "notification.action") {
            PhoneNotificationService.current?.execute(connection,wire) ?: connection.enqueue(decorate(Wire("action.result",obj("commandId" to wire.id,"state" to "failed","code" to "notification_access_unavailable","reason" to "Notification access is unavailable. Open Android Sync → Setup and enable notification access."),replyTo = wire.id)))
            return
        }
        if (!seen.insert(wire.id)) return
        val b = wire.body
        when (wire.type) {
            "notifications.refresh" -> { refreshPermissions(true); PhoneNotificationService.current?.snapshot(connection); reportPhoneStatus(connection) }
            "media.command" -> PhoneNotificationService.current?.executeMedia(connection,wire)
                ?: send(connection.peer.id,Wire("media.result",obj("state" to "failed","reason" to "Notification access is required for media controls."),replyTo = wire.id,capability = "media"))
            "media.refresh" -> PhoneNotificationService.current?.mediaSnapshot(connection)
            "device.revoked" -> { forget(connection.peer.id); fail("${connection.peer.name} removed this phone. Pair again to reconnect.") }
            "clipboard.propose", "clipboard.update" -> {
                val originId = b.optString("originDeviceId",wire.originDeviceId ?: connection.peer.id)
                if (!state.value.clipboardPaused && !state.value.pausedClipboardDevices.contains(originId)) {
                    val text = b.getString("text"); require(text.toByteArray().size <= CHUNK_SIZE)
                    synchronized(this) {
                        lastText = text; clipboard.setPrimaryClip(ClipData.newPlainText("Android Sync",text))
                        coordinateClipboard(
                            text = text,
                            origin = b.optString("origin",connection.peer.name),
                            sourceApp = b.optString("sourceApp").takeIf { it.isNotBlank() },
                            sourcePackage = b.optString("sourcePackage").takeIf { it.isNotBlank() },
                            eventId = b.optString("clipId",wire.id),
                            originDeviceId = originId,
                            createdAt = minOf(b.optLong("createdAt",wire.sentAt ?: System.currentTimeMillis()),System.currentTimeMillis() + 60_000)
                        )
                    }
                }
            }
            "clipboard.image.propose" -> {
                val originId = b.optString("originDeviceId",wire.originDeviceId ?: connection.peer.id)
                if (!state.value.clipboardPaused && !state.value.pausedClipboardDevices.contains(originId)) clipboardImages.receiveProposal(connection.peer.id,b)
            }
            "clipboard.delete" -> {
                val targetId = b.getString("targetId")
                rememberClipboardTombstone(targetId)
                deleteClipboardClip(targetId,everywhere = false)
                connections.keys.forEach { peerId -> if (peerId != connection.peer.id) send(peerId,wire) }
            }
            "link.share" -> {
                val url = b.getString("url"); if (url.isWebUrl()) { mutable.update { it.copy(links = (listOf(url) + it.links).take(30)) }; ConnectionService.notice(context,"Link received","Open Android Sync to view the shared link.") }
            }
            "file.offer" -> fileManager.receiveOffer(connection,FileOffer.parse(b))
            "file.accept" -> fileManager.acceptedByMac(connection,b.getString("transferId"))
            "file.decline", "file.cancel" -> fileManager.remoteCancel(connection.peer.id,b.getString("transferId"),wire.type == "file.decline")
            "file.complete" -> { val id = b.getString("transferId"); val transfer = transfer(id); require(transfer == null || (transfer.macId == connection.peer.id && !transfer.incoming && transfer.accepted)); if (transfer != null) updateTransfer(id) { it.copy(status = "Completed",bytes = it.total) } }
            "storage.list" -> sharedStorage.list(connection,wire.id,b.optString("path"),b.optInt("offset",0),b.optInt("limit",100))
            "storage.download" -> {
                val paths = b.getJSONArray("paths")
                sharedStorage.download(connection,b.optString("requestId",wire.id),(0 until paths.length()).map { paths.getString(it) })
            }
            "gallery.list" -> gallery.list(connection,wire.id,b.optInt("cursor",0),b.optInt("limit",20))
            "gallery.thumbnail" -> gallery.thumbnail(connection,wire.id,b.getString("mediaId"))
            "gallery.download" -> {
                val ids = b.getJSONArray("mediaIds")
                gallery.download(connection,b.optString("requestId",wire.id),(0 until ids.length()).map { ids.getString(it) })
            }
            "sms.refresh" -> if (state.value.messageDevices.contains(connection.peer.id)) messages.snapshot(connection) else send(connection.peer.id,Wire("sms.snapshot.error",obj("reason" to "Enable Messages access for this Mac on Android."),capability = "sms"))
            "contacts.refresh" -> if (state.value.messageDevices.contains(connection.peer.id)) messages.contacts(connection) else send(connection.peer.id,Wire("contacts.snapshot.error",obj("reason" to "Enable Messages access for this Mac on Android."),capability = "sms"))
            "sms.send" -> if (state.value.messageDevices.contains(connection.peer.id)) messages.send(connection,wire) else send(connection.peer.id,Wire("sms.send.result",obj("state" to "failed","reason" to "Enable Messages access for this Mac on Android."),replyTo = wire.id,capability = "sms"))
            "calls.page" -> if (state.value.messageDevices.contains(connection.peer.id)) messages.callHistory(connection,wire) else send(connection.peer.id,Wire("calls.page.error",obj("reason" to "Enable Messages access for this Mac on Android."),replyTo = wire.id,capability = "calls"))
            "calls.dial" -> if (state.value.messageDevices.contains(connection.peer.id)) messages.dial(connection,wire) else send(connection.peer.id,Wire("calls.dial.result",obj("state" to "failed","reason" to "Enable Messages access for this Mac on Android."),replyTo = wire.id,capability = "calls"))
            "stream.start" -> if (b.optString("kind") == "screen") screenMirror.request(connection,wire)
                else send(connection.peer.id,Wire("stream.result",obj("sessionId" to b.optString("sessionId"),"state" to "failed","reason" to "Unsupported realtime stream kind."),replyTo = wire.id,capability = "realtime"))
            "stream.stop" -> {
                val session = b.optString("sessionId").takeIf { it.isNotBlank() }
                screenMirror.stop(connection.peer.id,session)
            }
            "stream.configure" -> {
                val session = b.optString("sessionId")
                val requested = b.optInt("bitrate",4_000_000)
                val applied = screenMirror.configurePending(connection.peer.id,session,requested)
                send(connection.peer.id,Wire("stream.configure.result",obj(
                    "sessionId" to session,"state" to if (applied != null) "accepted" else "failed",
                    "requestedBitrate" to requested,"appliedBitrate" to applied,
                    "reason" to if (applied != null) "Bitrate will be applied when sharing starts." else "No matching pending screen-sharing request."
                ),replyTo = wire.id,capability = "realtime"))
            }
        }
    }
    @Synchronized private fun coordinateClipboard(
        text: String,
        origin: String,
        sourceApp: String? = null,
        sourcePackage: String? = null,
        eventId: String = UUID.randomUUID().toString(),
        originDeviceId: String = store.phoneId,
        createdAt: Long = System.currentTimeMillis(),
        recipients: Set<String> = connections.keys
    ) {
        revision++
        val acceptedClock = logicalClock.tick()
        val clip = ClipboardClip(
            id = eventId,kind = if (text.isWebUrl()) "link" else "text",text = text,
            originDevice = origin,sourceApp = sourceApp,sourcePackage = sourcePackage,
            createdAt = createdAt,syncedMacs = recipients,originDeviceId = originDeviceId,
            logicalClock = acceptedClock,contentHash = clipboardHash(text.toByteArray())
        )
        seen.insert(eventId)
        addClipboardClip(clip)
        mutable.update { it.copy(latestText = text,origin = origin) }
        val update = Wire(
            "clipboard.update",
            obj("clipId" to eventId,"text" to text,"origin" to origin,"sourceApp" to sourceApp,"sourcePackage" to sourcePackage,
                "originDeviceId" to originDeviceId,"createdAt" to createdAt,"contentHash" to clip.contentHash,
                "revision" to revision,"session" to clipboardSession,"acceptedClock" to acceptedClock),
            id = eventId,originDeviceId = originDeviceId,clock = acceptedClock,sentAt = createdAt,capability = "clipboard"
        )
        recipients.forEach { send(it,update) }
    }
    @Synchronized fun shareText(text: String, macId: String? = null, sourceApp: String? = "Android Sync") {
        if (text.toByteArray().size > CHUNK_SIZE) { fail("Text sharing is limited to 64 KiB."); return }
        if (state.value.clipboardPaused) { fail("Resume clipboard sharing first."); return }
        if (state.value.pausedClipboardDevices.contains(store.phoneId)) { fail("Resume clipboard sync for this device first."); return }
        lastText = text; clipboard.setPrimaryClip(ClipData.newPlainText("Android Sync",text))
        coordinateClipboard(text,Build.MODEL,sourceApp,context.packageName,recipients = macId?.let(::setOf) ?: connections.keys)
    }
    fun shareLink(text: String, macId: String) { if (text.isWebUrl()) send(macId,Wire("link.share",obj("url" to text))) else fail("Enter an http or https link.") }
    fun toggleClipboard() { mutable.update { it.copy(clipboardPaused = !it.clipboardPaused) }; safeSave("clipboard-paused",state.value.clipboardPaused.toString()); baselineClipboard(); reportPhoneStatus() }
    fun toggleClipboardDevice(deviceId: String) {
        val next = if (state.value.pausedClipboardDevices.contains(deviceId)) state.value.pausedClipboardDevices - deviceId else state.value.pausedClipboardDevices + deviceId
        mutable.update { it.copy(pausedClipboardDevices = next) }
        safeSave("clipboard-paused-devices",array(next).toString())
    }
    fun copyLatest() { clipboard.setPrimaryClip(ClipData.newPlainText("Android Sync",state.value.latestText)); lastText = state.value.latestText }
    fun copyClip(id: String) {
        val clip = state.value.clipboardClips.firstOrNull { it.id == id } ?: return
        if (clip.isImage) materializeClipboardImage(id,copyToPhone = true)
        else { markOwnClipboard("text:${clip.text}"); lastText = clip.text; clipboard.setPrimaryClip(ClipData.newPlainText("Android Sync",clip.text)) }
    }
    fun materializeClipboardImage(id: String, copyToPhone: Boolean = false) {
        scope.launch {
            runCatching {
                val current = state.value.clipboardClips.firstOrNull { it.id == id } ?: return@runCatching
                val ready = clipboardHistoryStore.materialize(current)
                mutable.update { value -> value.copy(clipboardClips = value.clipboardClips.map { if (it.id == id) ready else it }) }
                if (copyToPhone) clipboardImages.copyToPhone(ready)
            }.onFailure { fail("Could not open the encrypted clipboard image.") }
        }
    }
    fun clearClipboardHistory() {
        state.value.clipboardClips.forEach { clipboardImages.delete(it); clipboardHistoryStore.deleteArchive(it) }
        replaceClipboardHistory(emptyList())
    }
    fun shareCurrentClipboard() { captureCurrentClipboard() }
    fun captureCurrentClipboard(): Boolean {
        if (state.value.clipboardPaused) { fail("Resume clipboard sharing first."); return false }
        if (state.value.pausedClipboardDevices.contains(store.phoneId)) { fail("Resume clipboard sync for this device first."); return false }
        val clip = clipboard.primaryClip ?: run { fail("Android could not read the current clipboard. Copy the item again and retry."); return false }
        val sensitive = clip.description.extras?.getBoolean("android.content.extra.IS_SENSITIVE",false) == true
        if (sensitive) { fail("This clipboard item is marked sensitive and will not be shared."); return false }
        val item = clip.getItemAt(0)
        val text = item.text?.toString()
        if (!text.isNullOrEmpty()) { shareText(text,sourceApp = currentClipboardSource()?.app); return true }
        else item.uri?.let { uri ->
            val mime = clip.description.filterMimeTypes("image/*")?.firstOrNull() ?: context.contentResolver.getType(uri)
            if (mime?.startsWith("image/") == true) { clipboardImages.capture(uri,mime,currentClipboardSource()); return true }
            fail("The current clipboard item is not supported.")
        } ?: fail("The current clipboard item is empty.")
        return false
    }
    @Synchronized fun coordinateImage(clip: ClipboardClip, copyToPhone: Boolean = false) {
        if (state.value.clipboardPaused) { clipboardImages.delete(clip); return }
        revision++
        val clock = logicalClock.tick()
        val normalized = clip.copy(
            originDeviceId = clip.originDeviceId.ifBlank { store.phoneId },
            logicalClock = clock,
            contentHash = clip.contentHash.ifBlank { clip.imagePath?.let(::File)?.inputStream()?.use(::sha256) ?: "" }
        )
        seen.insert(normalized.id)
        addClipboardClip(normalized)
        mutable.update { it.copy(latestText = "Image · ${normalized.width} × ${normalized.height}",origin = normalized.originDevice) }
        if (copyToPhone) clipboardImages.copyToPhone(normalized)
        clipboardImages.push(normalized,revision,clipboardSession,connections.keys)
    }
    fun markClipboardSynced(id: String, macId: String) {
        replaceClipboardHistory(state.value.clipboardClips.map { if (it.id == id) it.copy(syncedMacs = it.syncedMacs + macId) else it })
    }
    @Synchronized fun markOwnClipboard(signature: String) { ownClipboardSignature = signature }
    @Synchronized fun noteClipboardSourcePackage(packageName: String?) { if (!packageName.isNullOrBlank() && packageName != context.packageName) { recentSourcePackage = packageName; recentSourceAt = System.currentTimeMillis() } }
    private fun currentClipboardSource(): ClipboardSource? {
        val packageName = recentSourcePackage?.takeIf { System.currentTimeMillis() - recentSourceAt < 5_000 } ?: return null
        val label = runCatching { context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(packageName,0)).toString() }.getOrNull()
        return ClipboardSource(label,packageName)
    }
    private fun addClipboardClip(clip: ClipboardClip) {
        if (clipboardTombstones.contains(clip.id)) { clipboardImages.delete(clip); clipboardHistoryStore.deleteArchive(clip); return }
        replaceClipboardHistory(listOf(clip) + state.value.clipboardClips.filterNot { it.id == clip.id })
    }
    @Synchronized private fun replaceClipboardHistory(values: List<ClipboardClip>) {
        val (retained,evicted) = ClipboardQuota.retain(values,state.value.clipboardQuotaBytes)
        evicted.forEach { clipboardImages.delete(it); clipboardHistoryStore.deleteArchive(it) }
        runCatching { clipboardHistoryStore.save(retained) }
            .onSuccess { saved -> mutable.update { it.copy(clipboardClips = saved) } }
            .onFailure { fail("Could not save encrypted clipboard history.") }
    }
    fun toggleClipboardPin(id: String) {
        replaceClipboardHistory(state.value.clipboardClips.map { if (it.id == id) it.copy(pinned = !it.pinned) else it })
    }
    fun deleteClipboardClip(id: String, everywhere: Boolean) {
        val clip = state.value.clipboardClips.firstOrNull { it.id == id } ?: return
        clipboardImages.delete(clip); clipboardHistoryStore.deleteArchive(clip)
        replaceClipboardHistory(state.value.clipboardClips.filterNot { it.id == id })
        if (everywhere) {
            rememberClipboardTombstone(id)
            broadcast(Wire("clipboard.delete",obj("targetId" to id),capability = "clipboard"))
        }
    }
    private fun rememberClipboardTombstone(id: String) {
        if (id.length > 128) return
        clipboardTombstones.add(id)
        while (clipboardTombstones.size > 4096) clipboardTombstones.remove(clipboardTombstones.first())
        safeSave("clipboard-tombstones",array(clipboardTombstones).toString())
    }
    fun setClipboardQuota(bytes: Long) {
        val quota = bytes.coerceIn(64L * 1024 * 1024,4L * 1024 * 1024 * 1024)
        safeSave("clipboard-quota",quota.toString())
        mutable.update { it.copy(clipboardQuotaBytes = quota) }
        replaceClipboardHistory(state.value.clipboardClips)
    }
    fun setOnboardingComplete(value: Boolean) { safeSave("onboarding-complete",value.toString()); mutable.update { it.copy(onboardingComplete = value) } }
    fun confirmBackgroundSetup(value: Boolean = true) { safeSave("background-setup-confirmed",value.toString()); mutable.update { it.copy(backgroundSetupConfirmed = value) } }
    fun setFileTransferEnabled(value: Boolean) { safeSave("file-transfer-enabled",value.toString()); mutable.update { it.copy(fileTransferEnabled = value) } }
    fun setStreamModeEnabled(value: Boolean) { safeSave("stream-mode-enabled",value.toString()); mutable.update { it.copy(streamModeEnabled = value) } }
    fun openAllFilesSettings() = sharedStorage.openPermissionSettings()
    fun setAskEveryTimeFiles(macId: String, value: Boolean) {
        val next = if (value) state.value.askEveryTimeFiles + macId else state.value.askEveryTimeFiles - macId
        safeSave("file-ask-every-time",array(next).toString())
        mutable.update { it.copy(askEveryTimeFiles = next) }
    }
    fun setMessageDevice(macId: String, value: Boolean) {
        if (value && !state.value.messagePermissions) { fail("Allow SMS and Contacts permissions in Settings first."); return }
        if (!value && state.value.messageDevices.contains(macId)) send(macId,Wire("sms.access.revoked",obj("reason" to "Messages access was disabled on Android."),capability = "sms"))
        val next = if (value) state.value.messageDevices + macId else state.value.messageDevices - macId
        safeSave("message-devices",array(next).toString())
        mutable.update { it.copy(messageDevices = next) }
        connections[macId]?.let { reportPhoneStatus(it) }
        if (value) connections[macId]?.let { messages.snapshot(it); messages.contacts(it) }
    }
    fun setScreenDevice(macId: String, value: Boolean) {
        val next = if (value) state.value.screenDevices + macId else state.value.screenDevices - macId
        if (!value) screenMirror.stop(macId,null)
        safeSave("screen-devices",array(next).toString()); mutable.update { it.copy(screenDevices = next) }
    }
    fun setControlDevice(macId: String, value: Boolean) {
        if (value && !state.value.accessibilityControl) { fail("Enable Android Sync remote control in Accessibility settings first."); return }
        val next = if (value) state.value.controlDevices + macId else state.value.controlDevices - macId
        safeSave("control-devices",array(next).toString()); mutable.update { it.copy(controlDevices = next) }
    }
    fun openAccessibilitySettings() { context.startActivity(android.content.Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }
    fun enableClipboardSync() { if (state.value.clipboardPaused) toggleClipboard() }
    fun updateTransfer(id: String, persist: Boolean = true, change: (TransferState) -> TransferState) {
        mutable.update { it.copy(transfers = it.transfers.map { t -> if (t.offer.id == id) change(t) else t }) }
        if (persist) persistTransfers()
    }
    fun addTransfer(value: TransferState) { mutable.update { it.copy(transfers = listOf(value) + it.transfers) }; persistTransfers() }
    fun persistTransfers() {
        runCatching {
            store.put("transfers",array(state.value.transfers.map { it.json() }).toString())
            fileManager.cleanupTerminal()
        }.onFailure { fail("Could not save encrypted transfer state.") }
    }
    fun setPreparing(value: Boolean) { mutable.update { it.copy(preparing = value) } }
    fun transfer(id: String) = state.value.transfers.firstOrNull { it.offer.id == id }
    private fun restoreTransfers(connection: MacConnection) {
        state.value.transfers.filter { it.macId == connection.peer.id && it.status !in listOf("Completed","Declined","Cancelled") }.forEach { transfer ->
            if (!transfer.incoming) connection.io.send(Wire("file.offer",transfer.offer.json()))
            else if (transfer.accepted) fileManager.acceptIncoming(transfer.offer.id)
        }
    }
}
