package dev.androidsync

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telecom.TelecomManager

/** Only included in the privately distributed build. No real call is used in automated tests. */
@Suppress("DEPRECATION")
internal fun platformCarrierCallControl(context: Context, action: String): NotificationActionResult {
    if (context.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) != PackageManager.PERMISSION_GRANTED)
        return NotificationActionResult("failed","call_permission_required","Allow Phone calls in Android Sync Setup.")
    val telecom = context.getSystemService(TelecomManager::class.java)
    return when (action) {
        "telecom:end" -> if (telecom.endCall())
            NotificationActionResult("uncertain","telecom_end_requested","Android Telecom received the end-call request, but did not confirm the call ended. Check your phone.")
        else NotificationActionResult("failed","no_active_call","Android reports no foreground call to end or decline.")
        "telecom:answer" -> {
            telecom.acceptRingingCall()
            NotificationActionResult("uncertain","telecom_answer_requested","Android Telecom received the answer request. Check the phone for the call state.")
        }
        else -> NotificationActionResult("failed","call_action_unavailable","This cellular call control is unavailable.")
    }
}
