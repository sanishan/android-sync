package dev.androidsync

import android.app.Notification
import android.app.Person
import android.Manifest
import android.content.ComponentName
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.provider.ContactsContract
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Patterns
import androidx.core.graphics.drawable.toBitmap
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

class PhoneNotificationService : NotificationListenerService() {
    companion object { const val TEST_ID = 4242; @Volatile var current: PhoneNotificationService? = null }
    private data class CachedAppIcon(val updatedAt: Long, val encodedPng: String)
    private val appIcons = ConcurrentHashMap<String,CachedAppIcon>()
    override fun onListenerConnected() { current = this; engine().refreshPermissions(); engine().connections.values.forEach { snapshot(it); mediaSnapshot(it) } }
    override fun onListenerDisconnected() { if (current === this) current = null; engine().refreshPermissions() }
    override fun onDestroy() { if (current === this) current = null; engine().refreshPermissions(); super.onDestroy() }
    @Synchronized override fun onNotificationPosted(sbn: StatusBarNotification) { payload(sbn)?.let { engine().broadcast(Wire("notification.upsert",it)) }; broadcastMedia() }
    @Synchronized override fun onNotificationRemoved(sbn: StatusBarNotification) { if (sbn.packageName != packageName || sbn.id == TEST_ID) engine().broadcast(Wire("notification.remove",obj("key" to sbn.key))); broadcastMedia() }
    @Synchronized fun snapshot(connection: MacConnection) {
        val messages = mutableListOf(Wire("notifications.begin"))
        activeNotifications?.forEach { sbn -> payload(sbn)?.also { it.put("snapshot",true) }?.let { messages.add(Wire("notification.upsert",it)) } }
        messages.add(Wire("notifications.end")); connection.enqueueBatch(messages.map(engine()::decorate))
    }
    internal fun payload(sbn: StatusBarNotification): JSONObject? {
        val n = sbn.notification; val extras = n.extras
        val isCall = NotificationActions.isCallNotification(n)
        if ((sbn.packageName == packageName && sbn.id != TEST_ID) || (n.flags and Notification.FLAG_GROUP_SUMMARY != 0 && !isCall)) return null
        val applicationInfo = runCatching { packageManager.getApplicationInfo(sbn.packageName,0) }.getOrNull()
        val app = applicationInfo?.let { packageManager.getApplicationLabel(it).toString() } ?: sbn.packageName
        val appIcon = applicationInfo?.let { encodedAppIcon(sbn.packageName, it) }
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.take(2000) ?: ""
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.take(16000) ?: ""
        val actions = n.actions ?: emptyArray()
        val defaultDialerCall = NotificationActions.isDefaultDialerCall(this,sbn)
        val carrierControl = defaultDialerCall && checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED
        val callActions = NotificationActions.callActions(n,carrierControl).filter { carrierControl || !defaultDialerCall || it.kind !in setOf("answer","decline") }
        val caller = if (isCall) callerDetails(n,title) else null
        val callState = if (isCall) when (extras.getInt(Notification.EXTRA_CALL_TYPE,Notification.CallStyle.CALL_TYPE_UNKNOWN)) {
            Notification.CallStyle.CALL_TYPE_INCOMING -> "incoming"
            Notification.CallStyle.CALL_TYPE_ONGOING -> "ongoing"
            Notification.CallStyle.CALL_TYPE_SCREENING -> "screening"
            else -> if (callActions.any { it.kind == "answer" }) "incoming" else "unknown"
        } else null
        val reply = callActions.isEmpty() && NotificationActions.replyAction(actions) != null
        val links = mutableSetOf<String>()
        val matcher = Patterns.WEB_URL.matcher("$title $text")
        while (matcher.find() && links.size < 10) { val link = matcher.group(); if (link.isWebUrl()) links.add(link) }
        val callActionIds = callActions.map { it.id }.toSet()
        val other = actions.mapIndexedNotNull { index, action -> if (action.remoteInputs?.isNotEmpty() == true || "action:$index" in callActionIds) null else obj("id" to index.toString(),"title" to action.title.toString().take(200)) }.take(10)
        val exposedCalls = callActions.map { obj("id" to it.id,"kind" to it.kind,"title" to it.title,"requiresText" to it.requiresText) }
        return obj("id" to sbn.key,"app" to app,"package" to sbn.packageName,"appIcon" to appIcon,"title" to title,"text" to text,"timestamp" to sbn.postTime,"active" to true,"reply" to reply,"links" to array(links),"actions" to array(other),"call" to isCall,"callState" to callState,"callerName" to caller?.name,"callerNumber" to caller?.number,"callerImage" to caller?.image,"callActions" to array(exposedCalls))
    }
    private fun encodedAppIcon(packageName: String, info: android.content.pm.ApplicationInfo): String? = runCatching {
        val updatedAt = packageManager.getPackageInfo(packageName,0).lastUpdateTime
        appIcons[packageName]?.takeIf { it.updatedAt == updatedAt }?.let { return@runCatching it.encodedPng }
        val bitmap = packageManager.getApplicationIcon(info).toBitmap(96,96,Bitmap.Config.ARGB_8888)
        val output = ByteArrayOutputStream()
        check(bitmap.compress(Bitmap.CompressFormat.PNG,100,output))
        val png = output.toByteArray()
        check(png.isNotEmpty() && png.size <= 64 * 1024)
        Base64.encodeToString(png,Base64.NO_WRAP).also { appIcons[packageName] = CachedAppIcon(updatedAt,it) }
    }.getOrNull()
    private data class CallerDetails(val name: String?, val number: String?, val image: String?)
    @Suppress("DEPRECATION")
    private fun callPerson(notification: Notification): Person? = if (android.os.Build.VERSION.SDK_INT >= 33) notification.extras?.getParcelable(Notification.EXTRA_CALL_PERSON,Person::class.java) else notification.extras?.getParcelable(Notification.EXTRA_CALL_PERSON)
    private fun callerDetails(notification: Notification, title: String): CallerDetails {
        val person = runCatching { callPerson(notification) }.getOrNull()
        val uri = person?.uri.orEmpty()
        val numberFromPerson = if (uri.startsWith("tel:",ignoreCase = true)) Uri.decode(uri.substringAfter(':')).take(100) else null
        val titleNumber = title.takeIf { value -> value.count(Char::isDigit) >= 7 && value.all { it.isDigit() || it in " +()-" } }?.take(100)
        val number = numberFromPerson ?: titleNumber
        var name = person?.name?.toString()?.trim()?.take(300)?.takeIf { it.isNotEmpty() && it != number }
        var image = runCatching { person?.icon?.loadDrawable(this)?.toBitmap(96,96,Bitmap.Config.ARGB_8888)?.let(::encodedBitmap) }.getOrNull()
        if (number != null && checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) runCatching {
            val lookup = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI,Uri.encode(number))
            val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME,ContactsContract.PhoneLookup.PHOTO_THUMBNAIL_URI)
            contentResolver.query(lookup,projection,null,null,null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    if (name == null) name = cursor.getString(cursor.getColumnIndexOrThrow(ContactsContract.PhoneLookup.DISPLAY_NAME))?.trim()?.take(300)?.takeIf(String::isNotEmpty)
                    if (image == null) cursor.getString(cursor.getColumnIndexOrThrow(ContactsContract.PhoneLookup.PHOTO_THUMBNAIL_URI))?.let { photoUri ->
                        contentResolver.openInputStream(Uri.parse(photoUri))?.use { input -> BitmapFactory.decodeStream(input)?.let { bitmap -> image = encodedBitmap(Bitmap.createScaledBitmap(bitmap,96,96,true)) } }
                    }
                }
            }
        }
        return CallerDetails(name,number,image)
    }
    private fun encodedBitmap(bitmap: Bitmap): String? = runCatching {
        val output = ByteArrayOutputStream(); check(bitmap.compress(Bitmap.CompressFormat.PNG,100,output))
        output.toByteArray().takeIf { it.isNotEmpty() && it.size <= 64 * 1024 }?.let { Base64.encodeToString(it,Base64.NO_WRAP) }
    }.getOrNull()
    private val actionHandler by lazy { NotificationActions(this,engine().store) { key -> activeNotifications?.firstOrNull { it.key == key } } }
    @Synchronized fun execute(connection: MacConnection, command: Wire) {
        val result = actionHandler.handle(command)
        connection.enqueue(engine().decorate(Wire("action.result",result.json().put("commandId",command.id),replyTo = command.id)))
        if (result.code == "notification_inactive") {
            command.body.optString("key").takeIf { it.isNotEmpty() }?.let { engine().broadcast(Wire("notification.remove",obj("key" to it))) }
        } else if (result.code in listOf("notification_changed","reply_unavailable","action_expired")) {
            engine().connections.values.forEach { snapshot(it) }
        }
    }

    @Synchronized fun mediaSnapshot(connection: MacConnection) {
        val state = currentMedia()
        connection.enqueue(engine().decorate(Wire("media.state",state?.json() ?: obj("active" to false),capability = "media")))
    }

    @Synchronized fun executeMedia(connection: MacConnection, command: Wire) {
        val result = runCatching {
            val action = command.body.getString("action")
            val packageName = command.body.optString("packageName")
            val controller = controllers().firstOrNull { packageName.isBlank() || it.packageName == packageName } ?: error("No matching Android media session is active.")
            val supported = actions(controller.playbackState?.actions ?: 0)
            require(action in supported) { "The active media application does not expose $action." }
            when (action) {
                "play" -> controller.transportControls.play()
                "pause" -> controller.transportControls.pause()
                "previous" -> controller.transportControls.skipToPrevious()
                "next" -> controller.transportControls.skipToNext()
                else -> error("Unsupported media command.")
            }
            true to "Media command accepted by Android."
        }.getOrElse { false to (it.message ?: "Android rejected the media command.") }
        connection.enqueue(engine().decorate(Wire("media.result",obj("state" to if (result.first) "accepted" else "failed","reason" to result.second),replyTo = command.id,capability = "media")))
        broadcastMedia()
    }

    private fun broadcastMedia() { engine().connections.values.forEach(::mediaSnapshot) }
    private fun controllers(): List<MediaController> = runCatching {
        getSystemService(MediaSessionManager::class.java).getActiveSessions(ComponentName(this,PhoneNotificationService::class.java))
    }.getOrDefault(emptyList())
    private fun currentMedia(): MediaStateRecord? {
        val controller = controllers().sortedByDescending { it.playbackState?.state == PlaybackState.STATE_PLAYING }.firstOrNull() ?: return null
        val metadata = controller.metadata
        val app = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(controller.packageName,0)).toString() }.getOrDefault(controller.packageName)
        return MediaStateRecord(controller.packageName,app,metadata?.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty().take(500),metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty().take(500),controller.playbackState?.state == PlaybackState.STATE_PLAYING,actions(controller.playbackState?.actions ?: 0))
    }
    private fun actions(mask: Long): List<String> = buildList {
        if (mask and PlaybackState.ACTION_PLAY != 0L) add("play")
        if (mask and PlaybackState.ACTION_PAUSE != 0L) add("pause")
        if (mask and PlaybackState.ACTION_PLAY_PAUSE != 0L) { if ("play" !in this) add("play"); if ("pause" !in this) add("pause") }
        if (mask and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L) add("previous")
        if (mask and PlaybackState.ACTION_SKIP_TO_NEXT != 0L) add("next")
    }
}
