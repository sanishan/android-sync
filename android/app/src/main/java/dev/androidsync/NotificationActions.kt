package dev.androidsync

import android.app.ActivityOptions
import android.os.Build
import android.app.KeyguardManager
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
import org.json.JSONObject

data class NotificationActionResult(val state: String, val code: String, val reason: String) {
    fun json() = obj("state" to state,"code" to code,"reason" to reason)
    companion object {
        fun parse(value: Any?): NotificationActionResult? = when (value) {
            is JSONObject -> NotificationActionResult(value.optString("state","uncertain"),value.optString("code"),value.optString("reason"))
            is String -> NotificationActionResult(value,"legacy","This action was already processed; it was not sent again.")
            else -> null
        }
    }
}

/** Always resolve the live notification. Persist outcomes, never reply text. */
class NotificationActions(
    private val context: Context,
    private val store: SecureStore,
    private val locked: () -> Boolean = { context.getSystemService(KeyguardManager::class.java).isDeviceLocked },
    private val resolve: (String) -> StatusBarNotification?
) {
    companion object {
        data class ExposedCallAction(val id: String, val kind: String, val title: String, val requiresText: Boolean)
        private data class CallTarget(val pendingIntent: PendingIntent, val remoteInputs: Array<RemoteInput> = emptyArray(), val authenticationRequired: Boolean = false)

        fun replyAction(actions: Array<Notification.Action>): Notification.Action? {
            val textActions = actions.filter { it.remoteInputs?.any { input -> input.allowFreeFormInput } == true }
            val replies = textActions.filter { it.semanticAction == Notification.Action.SEMANTIC_ACTION_REPLY }
            val candidates = replies.ifEmpty { textActions }
            return candidates.firstOrNull { it.actionIntent != null && !it.actionIntent.isImmutable }
        }

        /** Exposes only controls backed by a live PendingIntent from a call notification. */
        fun callActions(notification: Notification, carrierCall: Boolean = false): List<ExposedCallAction> {
            if (!isCallNotification(notification)) return emptyList()
            val result = linkedMapOf<String,ExposedCallAction>()
            (notification.actions ?: emptyArray()).forEachIndexed { index, action ->
                val pending = action.actionIntent ?: return@forEachIndexed
                if (isCallScreenShortcut(notification,pending)) return@forEachIndexed
                val title = action.title?.toString()?.trim().orEmpty().take(200)
                val inputs = action.remoteInputs?.filter { it.allowFreeFormInput }?.toTypedArray().orEmpty()
                val kind = classifyCallAction(action.semanticAction,title,inputs.isNotEmpty()) ?: return@forEachIndexed
                if (inputs.isNotEmpty() && pending.isImmutable) return@forEachIndexed
                if (result.values.any { it.kind == kind }) return@forEachIndexed
                val id = "action:$index"
                result.putIfAbsent(id,ExposedCallAction(id,kind,displayCallTitle(kind,title),inputs.isNotEmpty()))
            }
            // Prefer the actual notification button, including its authentication
            // requirement. Some OEM CallStyle extras merely open the call screen.
            listOf(
                Triple(Notification.EXTRA_ANSWER_INTENT,"call:answer","answer"),
                Triple(Notification.EXTRA_DECLINE_INTENT,"call:decline","decline"),
                Triple(Notification.EXTRA_HANG_UP_INTENT,"call:hangup","decline")
            ).forEach { (key,id,kind) ->
                val pending = callPendingIntent(notification,key)
                if (pending != null && !isCallScreenShortcut(notification,pending) && result.values.none { it.kind == kind }) {
                    result[id] = ExposedCallAction(id,kind,if (id == "call:hangup") "End call" else displayCallTitle(kind,""),false)
                }
            }
            if (!carrierCall) return result.values.toList().take(6)
            // Notification PendingIntents from some dialers only bring up the in-call
            // screen. Prefer Telecom for calls owned by the current default dialer.
            val incoming = notification.extras?.getInt(Notification.EXTRA_CALL_TYPE,Notification.CallStyle.CALL_TYPE_UNKNOWN) == Notification.CallStyle.CALL_TYPE_INCOMING || result.values.any { it.kind == "answer" }
            val direct = mutableListOf<ExposedCallAction>()
            if (incoming) direct += ExposedCallAction("telecom:answer","answer","Answer",false)
            direct += ExposedCallAction("telecom:end","decline",if (incoming) "Decline" else "End call",false)
            return (direct + result.values.filter { action -> direct.none { it.kind == action.kind } }).take(6)
        }

        fun isDefaultDialerCall(context: Context, notification: StatusBarNotification): Boolean =
            isCallNotification(notification.notification) && runCatching {
                val telecom = context.getSystemService(TelecomManager::class.java)
                val dialer = telecom.defaultDialerPackage ?: return@runCatching false
                notification.packageName == dialer ||
                    // Samsung may post the system call alert from its separate,
                    // platform-signed in-call UI rather than the dialer package.
                    (dialer == "com.samsung.android.dialer" && notification.packageName == "com.samsung.android.incallui" &&
                        context.packageManager.checkSignatures(dialer,notification.packageName) == PackageManager.SIGNATURE_MATCH)
            }.getOrDefault(false)

        private fun isCallScreenShortcut(notification: Notification, pending: PendingIntent): Boolean =
            pending == notification.contentIntent || pending == notification.fullScreenIntent

        fun isCallNotification(notification: Notification): Boolean = notification.category == Notification.CATEGORY_CALL ||
            listOf(Notification.EXTRA_ANSWER_INTENT,Notification.EXTRA_DECLINE_INTENT,Notification.EXTRA_HANG_UP_INTENT).any { notification.extras?.containsKey(it) == true }

        private fun classifyCallAction(semantic: Int, title: String, hasText: Boolean): String? {
            val normalized = title.lowercase().replace(Regex("[^a-z]+")," ").trim()
            if (hasText) return if (semantic == Notification.Action.SEMANTIC_ACTION_REPLY || listOf("message","reply","respond","decline").any { normalized.contains(it) }) "declineMessage" else null
            if (semantic == Notification.Action.SEMANTIC_ACTION_MUTE || normalized == "mute" || normalized.contains("mute microphone")) return "mute"
            if (semantic == Notification.Action.SEMANTIC_ACTION_UNMUTE || normalized == "unmute") return "mute"
            if (listOf("answer","accept","pick up","pickup").any { normalized.contains(it) }) return "answer"
            if (listOf("decline","reject","hang up","hangup","end call").any { normalized.contains(it) }) return "decline"
            return null
        }

        private fun displayCallTitle(kind: String, title: String): String = title.ifBlank {
            when (kind) { "answer" -> "Answer"; "decline" -> "Decline"; "mute" -> "Mute"; else -> "Decline with Message" }
        }

        @Suppress("DEPRECATION")
        private fun callPendingIntent(notification: Notification, key: String): PendingIntent? = if (android.os.Build.VERSION.SDK_INT >= 33) {
            notification.extras?.getParcelable(key,PendingIntent::class.java)
        } else notification.extras?.getParcelable(key)

        private fun resolveCallTarget(notification: Notification, id: String): CallTarget? {
            if (callActions(notification).none { it.id == id }) return null
            val special = when (id) {
                "call:answer" -> Notification.EXTRA_ANSWER_INTENT
                "call:decline" -> Notification.EXTRA_DECLINE_INTENT
                "call:hangup" -> Notification.EXTRA_HANG_UP_INTENT
                else -> null
            }
            if (special != null) return callPendingIntent(notification,special)?.let(::CallTarget)
            val index = id.removePrefix("action:").takeIf { id.startsWith("action:") }?.toIntOrNull() ?: return null
            val action = (notification.actions ?: emptyArray()).getOrNull(index) ?: return null
            if (callActions(notification).none { it.id == id }) return null
            val inputs = mutableListOf<RemoteInput>()
            action.remoteInputs?.forEach { if (it.allowFreeFormInput) inputs.add(it) }
            return action.actionIntent?.let { CallTarget(it,inputs.toTypedArray(),action.isAuthenticationRequired) }
        }
    }
    @Synchronized fun handle(command: Wire): NotificationActionResult {
        val journal = try { JSONObject(store.get("action-journal") ?: "{}") }
        catch (_: Exception) { return failed("storage_unavailable","Secure action storage is unavailable. Reopen Android Sync on your phone.") }
        NotificationActionResult.parse(journal.opt(command.id))?.let { return it }
        var dispatchStarted = false
        val result = try {
            val body = command.body
            val notification = resolve(body.getString("key")) ?: throw ActionFailure("notification_inactive","This notification is no longer on your phone. Reply to a current notification.")
            if (body.has("expectedTimestamp") && body.getLong("expectedTimestamp") != notification.postTime) {
                throw ActionFailure("notification_changed","This notification changed on your phone. Review the latest notification before replying.")
            }
            val kind = body.getString("kind")
            var pendingIntent: PendingIntent? = null
            var authenticationRequired = false
            var directCall: String? = null
            val intent: Intent?
            when (kind) {
                "reply" -> {
                    val text = body.getString("text")
                    if (text.isBlank() || text.length > 16000) throw ActionFailure("invalid_reply","Enter a reply of at most 16,000 characters.")
                    val action = replyAction(notification.notification.actions ?: emptyArray())
                        ?: throw ActionFailure("reply_unavailable","This Android notification does not expose a usable text reply. Reply on your phone.")
                    pendingIntent = action.actionIntent
                    authenticationRequired = action.isAuthenticationRequired
                    val inputs = action.remoteInputs.filter { it.allowFreeFormInput }.toTypedArray()
                    val values = Bundle(); inputs.forEach { values.putCharSequence(it.resultKey,text) }
                    intent = Intent()
                    RemoteInput.addResultsToIntent(inputs,intent,values)
                    RemoteInput.setResultsSource(intent,RemoteInput.SOURCE_FREE_FORM_INPUT)
                }
                "action" -> {
                    val index = body.getString("actionId").toInt()
                    val actions = notification.notification.actions ?: emptyArray()
                    val action = actions.getOrNull(index)?.takeIf { it.actionIntent != null && it.remoteInputs.isNullOrEmpty() }
                        ?: throw ActionFailure("action_unavailable","This notification action is no longer available. Refresh notifications.")
                    pendingIntent = action.actionIntent
                    authenticationRequired = action.isAuthenticationRequired
                    intent = null
                }
                "call" -> {
                    val actionId = body.getString("actionId")
                    if (actionId == "telecom:answer" || actionId == "telecom:end") {
                        if (!isDefaultDialerCall(context,notification) || callActions(notification.notification,true).none { it.id == actionId })
                            throw ActionFailure("call_action_unavailable","This cellular call control is no longer available.")
                        if (context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) != PackageManager.PERMISSION_GRANTED)
                            throw ActionFailure("call_permission_required","Allow Phone calls in Android Sync Setup before controlling cellular calls.")
                        directCall = actionId
                        intent = null
                    } else {
                        val target = resolveCallTarget(notification.notification,actionId)
                            ?: throw ActionFailure("call_action_unavailable","This call control is no longer available. Use the current call notification.")
                        pendingIntent = target.pendingIntent
                        authenticationRequired = target.authenticationRequired
                        if (target.remoteInputs.isNotEmpty()) {
                            val text = body.optString("text")
                            if (text.isBlank() || text.length > 16000) throw ActionFailure("invalid_call_message","Enter a message of at most 16,000 characters.")
                            val values = Bundle(); target.remoteInputs.forEach { values.putCharSequence(it.resultKey,text) }
                            intent = Intent()
                            RemoteInput.addResultsToIntent(target.remoteInputs,intent,values)
                            RemoteInput.setResultsSource(intent,RemoteInput.SOURCE_FREE_FORM_INPUT)
                        } else intent = null
                    }
                }
                "dismiss" -> { intent = null }
                else -> throw ActionFailure("unsupported_action","This notification action is not supported.")
            }
            if (authenticationRequired && locked()) {
                throw ActionFailure("phone_locked","Unlock your phone before using this notification action.")
            }
            // A crash or lost result after dispatch must never cause automatic resending.
            save(journal,command.id,NotificationActionResult("uncertain","dispatch_pending","The action may have been sent. Check your phone before trying again."))
            dispatchStarted = true
            if (kind == "dismiss") (context as android.service.notification.NotificationListenerService).cancelNotification(notification.key)
            else if (directCall != null) { /* The flavor-specific controller performs the call below. */ }
            else if (kind == "call" && pendingIntent!!.isActivity && Build.VERSION.SDK_INT >= 34) {
                // This dispatch follows an explicit authenticated desktop button press.
                // Samsung call actions can launch InCallActivity; default sender BAL
                // policy silently blocks it on Android 14+ even when send() returns.
                val options = ActivityOptions.makeBasic().apply {
                    setPendingIntentBackgroundActivityStartMode(
                        if (Build.VERSION.SDK_INT >= 36) ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
                        else ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                    )
                }
                pendingIntent.send(context,0,intent,null,null,null,options.toBundle())
            }
            else if (intent != null) pendingIntent!!.send(context,0,intent)
            else pendingIntent!!.send()
            if (directCall != null) platformCarrierCallControl(context,directCall)
            else if (kind == "call") NotificationActionResult("uncertain","call_dispatched","Request sent to the phone app. The call change is not confirmed; check your phone.")
            else NotificationActionResult("accepted","action_accepted","Android accepted the action. Message delivery is controlled by the source app.")
        } catch (e: ActionFailure) { failed(e.code,e.detail) }
        catch (_: PendingIntent.CanceledException) { failed("action_expired","The Android app expired this notification action. Wait for a new notification or reply on your phone.") }
        catch (_: SecurityException) { failed("permission_denied","Android blocked this notification action. Check notification access and unlock your phone.") }
        catch (_: Exception) {
            if (dispatchStarted) NotificationActionResult("uncertain","dispatch_uncertain","The action may have been sent. Check your phone before trying again.")
            else failed("invalid_action","The action could not be prepared. Refresh notifications and try a current notification.")
        }
        return try { save(journal,command.id,result); result }
        catch (_: Exception) {
            if (dispatchStarted) NotificationActionResult("uncertain","storage_unavailable","The action may have been sent, but its result could not be saved. Check your phone.")
            else failed("storage_unavailable","The action was not sent because secure storage is unavailable.")
        }
    }
    private fun save(journal: JSONObject, id: String, result: NotificationActionResult) {
        journal.put(id,result.json())
        while (journal.length() > 512) journal.remove(journal.keys().asSequence().first { it != id })
        store.put("action-journal",journal.toString())
    }
    private fun failed(code: String, reason: String) = NotificationActionResult("failed",code,reason)
    private class ActionFailure(val code: String, val detail: String): Exception()
}
