package dev.androidsync

import android.content.Context

internal fun platformCarrierCallControl(context: Context, action: String): NotificationActionResult =
    NotificationActionResult("failed","call_unavailable","Direct cellular call control is available only in the private localFull build.")
