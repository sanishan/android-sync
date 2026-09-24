package dev.androidsync

import android.Manifest
import android.content.Context
import android.content.Intent
import android.companion.CompanionDeviceManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat

enum class CapabilityStatus { ENABLED, AVAILABLE, PERMISSION_REQUIRED, TEMPORARILY_UNAVAILABLE, UNSUPPORTED }

data class FeatureCapability(
    val id: String,
    val label: String,
    val status: CapabilityStatus,
    val reason: String
)

data class DeviceCapabilitySet(val values: List<FeatureCapability>) {
    operator fun get(id: String): FeatureCapability? = values.firstOrNull { it.id == id }
}

data class PowerGuide(
    val vendor: String,
    val title: String,
    val detail: String,
    val intents: List<Intent>
)

object DeviceCapabilities {
    fun detect(context: Context, state: EngineState? = null): DeviceCapabilitySet {
        val notificationAccess = NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
        val allFiles = !BuildConfig.LOCAL_FULL || Environment.isExternalStorageManager()
        val contacts = context.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
        val smsRead = context.checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
        val smsSend = context.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
        @Suppress("DEPRECATION")
        val companion = state?.companionAssociated == true || (context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP) && runCatching {
            context.getSystemService(CompanionDeviceManager::class.java).let { manager ->
                if (Build.VERSION.SDK_INT >= 33) manager.myAssociations.isNotEmpty() else manager.associations.isNotEmpty()
            }
        }.getOrDefault(false))
        return DeviceCapabilitySet(listOf(
            FeatureCapability("connection", "Background connection", if (state?.enabled == true) CapabilityStatus.ENABLED else CapabilityStatus.AVAILABLE, "Visible connected-device service"),
            FeatureCapability("companion", "Companion association", if (companion) CapabilityStatus.ENABLED else CapabilityStatus.AVAILABLE, if (companion) "Registered with Android's companion-device service" else "Optional public Wi-Fi association can be added from Devices"),
            FeatureCapability("notifications", "Notifications and replies", if (notificationAccess) CapabilityStatus.ENABLED else CapabilityStatus.PERMISSION_REQUIRED, "Notification listener access"),
            FeatureCapability("clipboard", "Clipboard", if (state?.clipboardPaused == false) CapabilityStatus.ENABLED else CapabilityStatus.AVAILABLE, "Automatic while Android Sync is visible; system share actions elsewhere"),
            FeatureCapability("files", "Shared storage", if (allFiles) CapabilityStatus.ENABLED else CapabilityStatus.PERMISSION_REQUIRED, if (BuildConfig.LOCAL_FULL) "All Files Access for the private build" else "System file picker"),
            FeatureCapability("contacts", "Contacts", if (contacts) CapabilityStatus.ENABLED else CapabilityStatus.PERMISSION_REQUIRED, "Optional contact-name resolution"),
            FeatureCapability("sms", "Carrier SMS", if (smsRead && smsSend) CapabilityStatus.ENABLED else CapabilityStatus.PERMISSION_REQUIRED, if (BuildConfig.LOCAL_FULL) "Optional SMS-only access" else "Available only in the private local build"),
            FeatureCapability("screen", "Screen mirroring", CapabilityStatus.AVAILABLE, "Android asks for consent for every session"),
            FeatureCapability("control", "Remote control", if (state?.accessibilityControl == true) CapabilityStatus.ENABLED else if (BuildConfig.LOCAL_FULL) CapabilityStatus.PERMISSION_REQUIRED else CapabilityStatus.UNSUPPORTED, if (BuildConfig.LOCAL_FULL) "Optional Accessibility service" else "Available only in the private local build"),
            FeatureCapability("callControls", "Call controls", if (notificationAccess) CapabilityStatus.ENABLED else CapabilityStatus.PERMISSION_REQUIRED, "Uses only actions exposed by the active call notification; audio stays on the phone"),
            FeatureCapability("calls", "Call audio", CapabilityStatus.UNSUPPORTED, "Disabled until two-way audio passes device tests")
        ))
    }

    fun powerGuide(context: Context): PowerGuide {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val appDetails = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:${context.packageName}"))
        val generic = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        return when {
            manufacturer.contains("samsung") -> PowerGuide(
                "Samsung", "Never sleeping apps",
                "Set battery usage to Unrestricted and add Android Sync to Never sleeping apps.",
                listOf(Intent("com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY").setPackage("com.samsung.android.lool").putExtra("activity_type", 2), generic, appDetails)
            )
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") -> PowerGuide(
                "Xiaomi / Redmi", "Autostart and battery saver",
                "Enable Autostart and choose No restrictions for Android Sync.",
                listOf(Intent("miui.intent.action.POWER_HIDE_MODE_APP_LIST").setPackage("com.miui.powerkeeper"), generic, appDetails)
            )
            manufacturer.contains("oneplus") || manufacturer.contains("oppo") || manufacturer.contains("realme") -> PowerGuide(
                "OnePlus / Oppo", "Allow background activity",
                "Allow background activity, Auto launch, and unrestricted battery use.",
                listOf(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), appDetails)
            )
            manufacturer.contains("google") -> PowerGuide(
                "Google Pixel", "Unrestricted battery use",
                "Open App battery usage and select Unrestricted.",
                listOf(appDetails, generic)
            )
            else -> PowerGuide(
                Build.MANUFACTURER.ifBlank { "Android" }, "Allow background activity",
                "Allow unrestricted battery use or exclude Android Sync from battery optimization.",
                listOf(appDetails, generic)
            )
        }
    }

    fun openPowerSettings(context: Context): Boolean {
        for (intent in powerGuide(context).intents) {
            if (runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true }.getOrDefault(false)) return true
        }
        return false
    }
}
