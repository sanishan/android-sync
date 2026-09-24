package dev.androidsync

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.*
import android.util.Base64
import android.view.Surface
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.math.roundToInt

private const val MIRROR_NOTIFICATION_ID = 7041
private const val MIRROR_REQUEST_ID = 7042
private const val MIRROR_ACTIVE_CHANNEL = "screen-mirroring-active"
private const val MIRROR_REQUEST_CHANNEL = "screen-mirroring-requests-v2"
private const val VIDEO_CHUNK_BYTES = 48 * 1024

data class PendingMirror(val macId: String, val sessionId: String, val control: Boolean, val bitrate: Int, val expiresAt: Long)

class ScreenMirrorCoordinator(private val engine: SyncEngine) {
    @Volatile private var pending: PendingMirror? = null
    @Volatile private var launchingSession: String? = null

    @Synchronized fun request(connection: MacConnection, command: Wire) {
        val sessionId = command.body.optString("sessionId")
        if (sessionId.isBlank() || sessionId.length > 128) return result(connection.peer.id,command.id,"failed","Invalid mirroring session.")
        if (!engine.state.value.screenDevices.contains(connection.peer.id)) return result(connection.peer.id,command.id,"failed","Enable Screen mirroring for this Mac on Android first.")
        if (ScreenMirrorService.activeSession != null) return result(connection.peer.id,command.id,"temporarily_unavailable","Another screen session is already active.")
        pending?.takeIf { it.expiresAt >= System.currentTimeMillis() }?.let {
            return result(connection.peer.id,command.id,"temporarily_unavailable","A screen-sharing approval is already waiting on Android.")
        }
        val control = command.body.optBoolean("control") && engine.state.value.controlDevices.contains(connection.peer.id) && engine.remoteControl.enabled
        val bitrate = command.body.optInt("bitrate",4_000_000).coerceIn(1_000_000,12_000_000)
        pending = PendingMirror(connection.peer.id,sessionId,control,bitrate,System.currentTimeMillis() + 120_000)
        postConsentNotification(connection.peer.name,connection.peer.id,sessionId)
        // Android may allow this immediately while the app is visible or while
        // Android Sync has an active companion-device exemption. Other devices
        // block background activity launches, so the audible heads-up remains.
        val opened = launchPendingConsent()
        val reason = if (opened && (engine.foreground || engine.state.value.companionAssociated)) "Approve the Android system screen-sharing dialog now."
        else "Android Sync requested the screen-sharing dialog. If Android keeps it in the background, tap the audible approval notification."
        result(connection.peer.id,command.id,"awaiting_consent",reason,sessionId)
        engine.scope.launch {
            delay(120_000)
            expire(connection.peer.id,sessionId)
        }
    }

    private fun postConsentNotification(macName: String, macId: String, sessionId: String) {
        val manager = engine.context.getSystemService(NotificationManager::class.java)
        val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
        manager.createNotificationChannel(NotificationChannel(MIRROR_REQUEST_CHANNEL,"Screen sharing requests",NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Alerts when a trusted Mac asks to share this Android screen"
            enableVibration(true); vibrationPattern = longArrayOf(0,250,120,250)
            setSound(sound,attributes); lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        })
        val approve = consentIntent(macId,sessionId)
        val pendingIntent = PendingIntent.getActivity(engine.context,MIRROR_REQUEST_ID,approve,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify(MIRROR_REQUEST_ID,NotificationCompat.Builder(engine.context,MIRROR_REQUEST_CHANNEL)
            .setSmallIcon(R.drawable.ic_sync).setContentTitle("Approve screen sharing")
            .setContentText("Choose a screen or app to share with $macName.")
            .setContentIntent(pendingIntent).setAutoCancel(true).setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_EVENT).setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE).setVibrate(longArrayOf(0,250,120,250)).setSound(sound)
            .setTimeoutAfter(120_000)
            .addAction(0,"Start sharing",pendingIntent).build())
    }

    private fun consentIntent(macId: String, sessionId: String) = Intent(engine.context,MirrorConsentActivity::class.java)
        .putExtra("macId",macId).putExtra("sessionId",sessionId).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    @Synchronized fun launchPendingConsent(): Boolean {
        val value = pending?.takeIf { it.expiresAt >= System.currentTimeMillis() } ?: return false
        if (launchingSession == value.sessionId) return true
        launchingSession = value.sessionId
        val launch = {
            runCatching { engine.context.startActivity(consentIntent(value.macId,value.sessionId)) }
                .onFailure { synchronized(this) { if (launchingSession == value.sessionId) launchingSession = null } }
        }
        Handler(Looper.getMainLooper()).postDelayed({ synchronized(this) { if (pending?.sessionId == value.sessionId && launchingSession == value.sessionId) launchingSession = null } },2_000)
        if (Looper.myLooper() == Looper.getMainLooper()) return launch().isSuccess
        Handler(Looper.getMainLooper()).post { launch() }
        return true
    }

    @Synchronized fun consume(macId: String, sessionId: String): PendingMirror? {
        val value = pending?.takeIf { it.macId == macId && it.sessionId == sessionId && it.expiresAt >= System.currentTimeMillis() }
        if (pending?.sessionId == sessionId) pending = null
        if (launchingSession == sessionId) launchingSession = null
        cancelConsentNotification()
        return value
    }

    @Synchronized fun declined(macId: String, sessionId: String) {
        if (pending?.sessionId == sessionId) pending = null
        if (launchingSession == sessionId) launchingSession = null
        cancelConsentNotification()
        engine.send(macId,Wire("stream.result",obj("sessionId" to sessionId,"state" to "failed","reason" to "Screen sharing was not approved on Android."),capability = "realtime"))
    }

    @Synchronized fun stop(macId: String, sessionId: String?) {
        pending?.takeIf { it.macId == macId && (sessionId == null || it.sessionId == sessionId) }?.let {
            if (launchingSession == it.sessionId) launchingSession = null
            pending = null
            cancelConsentNotification()
        }
        ScreenMirrorService.stopIfOwned(macId,sessionId)
    }

    @Synchronized fun configurePending(macId: String, sessionId: String, requested: Int): Int? {
        val value = pending?.takeIf { it.macId == macId && it.sessionId == sessionId && it.expiresAt >= System.currentTimeMillis() } ?: return null
        val applied = requested.coerceIn(1_000_000,12_000_000)
        pending = value.copy(bitrate = applied)
        return applied
    }

    @Synchronized private fun expire(macId: String, sessionId: String) {
        val value = pending?.takeIf { it.macId == macId && it.sessionId == sessionId } ?: return
        if (value.expiresAt > System.currentTimeMillis()) return
        pending = null
        if (launchingSession == sessionId) launchingSession = null
        cancelConsentNotification()
        engine.send(macId,Wire("stream.result",obj("sessionId" to sessionId,"state" to "failed","reason" to "Screen-sharing approval expired. Start mirroring again."),capability = "realtime"))
    }

    private fun cancelConsentNotification() {
        engine.context.getSystemService(NotificationManager::class.java).cancel(MIRROR_REQUEST_ID)
    }

    private fun result(macId: String, replyTo: String, state: String, reason: String, sessionId: String? = null) {
        engine.send(macId,Wire("stream.result",obj("sessionId" to sessionId,"state" to state,"reason" to reason),replyTo = replyTo,capability = "realtime"))
    }
}

class MirrorConsentActivity : Activity() {
    private lateinit var macId: String
    private lateinit var sessionId: String
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        getSystemService(NotificationManager::class.java).cancel(MIRROR_REQUEST_ID)
        macId = intent.getStringExtra("macId").orEmpty(); sessionId = intent.getStringExtra("sessionId").orEmpty()
        if (macId.isBlank() || sessionId.isBlank()) { finish(); return }
        @Suppress("DEPRECATION")
        startActivityForResult(getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent(),1)
    }
    @Deprecated("Activity result retained for API 31 compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        val engine = engine(); val pending = engine.screenMirror.consume(macId,sessionId)
        if (requestCode == 1 && resultCode == RESULT_OK && data != null && pending != null) {
            val service = Intent(this,ScreenMirrorService::class.java).putExtra("resultCode",resultCode).putExtra("resultData",data)
                .putExtra("macId",macId).putExtra("sessionId",sessionId).putExtra("control",pending.control).putExtra("bitrate",pending.bitrate)
            ContextCompat.startForegroundService(this,service)
        } else engine.screenMirror.declined(macId,sessionId)
        finishAndRemoveTask()
    }
}

class ScreenMirrorService : Service() {
    companion object {
        @Volatile var activeSession: String? = null
        @Volatile private var activeMac: String? = null
        @Volatile private var instance: ScreenMirrorService? = null
        fun stopIfOwned(macId: String, sessionId: String?) { if (activeMac == macId && (sessionId == null || activeSession == sessionId)) instance?.stopSession("Stopped from the Mac.") }
    }
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var connection: MacConnection? = null
    private var worker: Job? = null
    private var sessionId = ""
    private var macId = ""
    private var control = false
    @Volatile private var stopping = false
    private var bitrate = 4_000_000
    private var targetBitrate = 4_000_000
    private var waitingForKeyFrame = false
    private var lastFrameDropAt = 0L
    private var lastBitrateAdjustmentAt = 0L
    private var spec: CaptureSpec? = null
    private val projectionCallback = object : MediaProjection.Callback() { override fun onStop() { stopSession("Android stopped screen sharing.") } }

    override fun onCreate() { super.onCreate(); instance = this }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") { stopSession("Stopped on Android."); return START_NOT_STICKY }
        if (activeSession != null) { stopSelf(); return START_NOT_STICKY }
        sessionId = intent?.getStringExtra("sessionId").orEmpty(); macId = intent?.getStringExtra("macId").orEmpty(); control = intent?.getBooleanExtra("control",false) == true
        bitrate = intent?.getIntExtra("bitrate",4_000_000)?.coerceIn(1_000_000,12_000_000) ?: 4_000_000; targetBitrate = bitrate
        @Suppress("DEPRECATION") val resultData = if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra("resultData",Intent::class.java) else intent?.getParcelableExtra("resultData")
        val resultCode = intent?.getIntExtra("resultCode",Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        val peer = engine().peerForLane(macId)
        if (sessionId.isBlank() || peer == null || resultData == null || resultCode != Activity.RESULT_OK) { stopSelf(); return START_NOT_STICKY }
        activeSession = sessionId; activeMac = macId
        startMirrorForeground(peer.name)
        worker = engine().scope.launch {
            try {
                val realtime = MacConnection.open(peer,engine().store,"realtime"); connection = realtime; realtime.startWriter(this)
                realtime.enqueue(engine().decorate(Wire("stream.offer",obj("sessionId" to sessionId,"kind" to "screen","codec" to "h264","control" to control),capability = "realtime")))
                val response = realtime.io.read()
                require(response.type == "stream.result" && response.body.optString("state") == "accepted" && response.body.optString("sessionId") == sessionId) { "Mac did not accept the screen stream." }
                startProjection(resultCode,resultData,realtime)
                val reader = launch {
                    try {
                        while (isActive) {
                            val command = realtime.io.read()
                            if (command.body.optString("sessionId") != sessionId) continue
                            when (command.type) {
                                "stream.stop" -> { stopSession("Stopped from the Mac."); return@launch }
                                "stream.configure" -> updateBitrate(realtime,command.body.optInt("bitrate",bitrate))
                                "stream.feedback" -> adaptBitrate(realtime,command.body.optInt("backlog",0))
                                "control.input" -> handleControl(realtime,command)
                            }
                        }
                    } catch (error: Exception) {
                        if (!stopping && error !is kotlinx.coroutines.CancellationException) stopSession("Mac ended screen sharing.")
                    }
                }
                drainEncoder(realtime)
                reader.cancel()
            } catch (e: Exception) {
                engine().send(macId,Wire("stream.result",obj("sessionId" to sessionId,"state" to "failed","reason" to (e.message ?: "Screen stream ended.")),capability = "realtime"))
            } finally { stopSession("Screen stream ended.") }
        }
        return START_NOT_STICKY
    }

    private fun startMirrorForeground(macName: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(MIRROR_ACTIVE_CHANNEL,"Active screen sharing",NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this,91,Intent(this,ScreenMirrorService::class.java).setAction("STOP"),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = NotificationCompat.Builder(this,MIRROR_ACTIVE_CHANNEL).setSmallIcon(R.drawable.ic_sync).setContentTitle("Sharing your Android screen")
            .setContentText("Streaming locally to $macName").setOngoing(true).addAction(0,"Stop",stop).build()
        ServiceCompat.startForeground(this,MIRROR_NOTIFICATION_ID,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
    }

    private fun startProjection(resultCode: Int, data: Intent, realtime: MacConnection) {
        val mediaProjection = getSystemService(MediaProjectionManager::class.java).getMediaProjection(resultCode,data) ?: error("Android did not provide a screen-capture session.")
        projection = mediaProjection; mediaProjection.registerCallback(projectionCallback,Handler(Looper.getMainLooper()))
        val initial = captureSpec(); val surface = configureCodec(initial)
        display = mediaProjection.createVirtualDisplay("Android Sync",initial.width,initial.height,initial.density,DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,surface,null,null)
        spec = initial
        engine().send(macId,Wire("stream.result",obj("sessionId" to sessionId,"state" to "streaming","reason" to "Screen sharing is active.","bitrate" to bitrate),capability = "realtime"))
    }

    private fun configureCodec(value: CaptureSpec): Surface {
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC,value.width,value.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE,bitrate); setInteger(MediaFormat.KEY_FRAME_RATE,30); setInteger(MediaFormat.KEY_I_FRAME_INTERVAL,1)
            if (Build.VERSION.SDK_INT >= 23) setInteger(MediaFormat.KEY_PRIORITY,0)
            if (Build.VERSION.SDK_INT >= 29) { setInteger(MediaFormat.KEY_MAX_B_FRAMES,0); setInteger(MediaFormat.KEY_LATENCY,0) }
            if (Build.VERSION.SDK_INT >= 30 && encoder.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                setFeatureEnabled(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency,true)
            }
        }
        encoder.configure(format,null,null,MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = encoder.createInputSurface(); encoder.start(); codec = encoder; inputSurface = surface
        return surface
    }

    private suspend fun drainEncoder(realtime: MacConnection) {
        val info = MediaCodec.BufferInfo(); var checkedAt = 0L
        while (engine().scope.isActive && !stopping) {
            val encoder = codec ?: break
            when (val index = encoder.dequeueOutputBuffer(info,10_000)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> sendConfig(realtime,encoder.outputFormat)
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                else -> if (index >= 0) {
                    encoder.getOutputBuffer(index)?.let { buffer ->
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) sendFrame(realtime,buffer,info)
                    }
                    encoder.releaseOutputBuffer(index,false)
                }
            }
            val now = System.currentTimeMillis()
            if (now - checkedAt > 750) { checkedAt = now; val next = captureSpec(); if (next != spec) reconfigure(next) }
        }
    }

    private fun sendConfig(realtime: MacConnection, format: MediaFormat) {
        fun bytes(name: String): String? = format.getByteBuffer(name)?.let { source -> ByteArray(source.remaining()).also { source.get(it) } }?.let { Base64.encodeToString(it,Base64.NO_WRAP) }
        val current = spec ?: captureSpec()
        realtime.enqueue(engine().decorate(Wire("stream.config",obj("sessionId" to sessionId,"codec" to "h264","width" to current.width,"height" to current.height,"rotation" to current.rotation,"csd0" to bytes("csd-0"),"csd1" to bytes("csd-1")),capability = "realtime")))
    }

    private fun sendFrame(realtime: MacConnection, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        buffer.position(info.offset); buffer.limit(info.offset + info.size)
        val keyFrame = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        if (waitingForKeyFrame && !keyFrame) return
        if (keyFrame) waitingForKeyFrame = false
        val data = ByteArray(info.size); buffer.get(data)
        val frameId = UUID.randomUUID().toString(); val chunks = data.asList().chunked(VIDEO_CHUNK_BYTES)
        val wires = chunks.mapIndexed { index, part ->
            Wire("stream.video",obj("sessionId" to sessionId,"frameId" to frameId,"index" to index,"count" to chunks.size,"pts" to info.presentationTimeUs,"key" to keyFrame,"data" to Base64.encodeToString(part.toByteArray(),Base64.NO_WRAP)),capability = "realtime")
        }
        if (realtime.enqueueLatestRealtimeFrame(wires.map(engine()::decorate))) {
            waitingForKeyFrame = true; lastFrameDropAt = SystemClock.elapsedRealtime()
            requestKeyFrame(); reduceBitrateForCongestion(realtime)
        }
    }

    private fun reconfigure(next: CaptureSpec) {
        val old = codec
        display?.surface = null
        runCatching { old?.stop() }; runCatching { old?.release() }; inputSurface?.release()
        val surface = configureCodec(next)
        display?.resize(next.width,next.height,next.density); display?.surface = surface; spec = next
    }

    private fun updateBitrate(realtime: MacConnection, requested: Int) {
        targetBitrate = requested.coerceIn(1_000_000,12_000_000); bitrate = targetBitrate
        val result = runCatching { codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE,bitrate) }) }
        realtime.enqueue(engine().decorate(Wire("stream.configure.result",obj("sessionId" to sessionId,"state" to if (result.isSuccess) "accepted" else "failed","requestedBitrate" to targetBitrate,"appliedBitrate" to bitrate,"reason" to if (result.isSuccess) "Encoder bitrate updated." else "The Android encoder rejected the bitrate change."),capability = "realtime")))
    }
    private fun adaptBitrate(realtime: MacConnection, backlog: Int) {
        val now = SystemClock.elapsedRealtime()
        val next = if (backlog >= 3) (bitrate * .8).roundToInt().coerceAtLeast(1_000_000)
        else if (now - lastFrameDropAt > 3_000) (bitrate + 250_000).coerceAtMost(targetBitrate) else bitrate
        if (next != bitrate) applyAdaptiveBitrate(realtime,next,if (next < bitrate) "Mac decode backlog" else "Network recovered")
    }
    private fun reduceBitrateForCongestion(realtime: MacConnection) {
        val now = SystemClock.elapsedRealtime(); if (now - lastBitrateAdjustmentAt < 750) return
        val next = (bitrate * .8).roundToInt().coerceAtLeast(1_000_000)
        if (next != bitrate) applyAdaptiveBitrate(realtime,next,"Realtime frame queue congestion")
    }
    private fun applyAdaptiveBitrate(realtime: MacConnection, next: Int, reason: String) {
        bitrate = next; lastBitrateAdjustmentAt = SystemClock.elapsedRealtime()
        runCatching { codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE,bitrate) }) }
        realtime.enqueue(engine().decorate(Wire("stream.configure.result",obj("sessionId" to sessionId,"state" to "adapted","requestedBitrate" to targetBitrate,"appliedBitrate" to bitrate,"reason" to reason),capability = "realtime")))
    }
    private fun requestKeyFrame() {
        runCatching { codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME,0) }) }
    }

    private fun handleControl(realtime: MacConnection, command: Wire) {
        val allowed = control && engine().state.value.controlDevices.contains(macId)
        val result = if (allowed) engine().remoteControl.execute(command) else false to "Remote control is not enabled for this Mac."
        realtime.enqueue(engine().decorate(Wire("control.result",obj("sessionId" to sessionId,"state" to if (result.first) "accepted" else "failed","reason" to result.second),replyTo = command.id,capability = "realtime")))
    }

    @Synchronized fun stopSession(reason: String) {
        if (stopping) return; stopping = true
        engine().send(macId,Wire("stream.result",obj("sessionId" to sessionId,"state" to "stopped","reason" to reason),capability = "realtime"))
        runCatching { display?.release() }; display = null
        runCatching { codec?.stop() }; runCatching { codec?.release() }; codec = null
        inputSurface?.release(); inputSurface = null
        projection?.let { runCatching { it.unregisterCallback(projectionCallback) }; runCatching { it.stop() } }; projection = null
        connection?.close(); connection = null; worker?.cancel(); worker = null
        activeSession = null; activeMac = null; if (instance === this) instance = null
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }

    override fun onDestroy() { if (!stopping) stopSession("Screen sharing service stopped."); super.onDestroy() }

    private fun captureSpec(): CaptureSpec {
        val bounds: Rect = getSystemService(WindowManager::class.java).currentWindowMetrics.bounds
        val rawWidth = bounds.width().coerceAtLeast(2); val rawHeight = bounds.height().coerceAtLeast(2)
        val scale = (1280.0 / maxOf(rawWidth,rawHeight)).coerceAtMost(1.0)
        fun even(value: Int) = (value / 2 * 2).coerceAtLeast(2)
        val width = even((rawWidth * scale).roundToInt()); val height = even((rawHeight * scale).roundToInt())
        val rotation = if (rawWidth > rawHeight) 90 else 0
        return CaptureSpec(width,height,resources.displayMetrics.densityDpi,rotation)
    }
    private data class CaptureSpec(val width: Int, val height: Int, val density: Int, val rotation: Int)
}
