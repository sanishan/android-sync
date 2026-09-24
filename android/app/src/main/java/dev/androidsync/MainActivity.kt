package dev.androidsync

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {
    private val shared = mutableStateOf<SharedIntent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        acceptIntent(intent)
        setContent {
            val state by engine().state.collectAsStateWithLifecycle()
            AndroidSyncTheme {
                if (state.onboardingComplete) SyncScreen(engine(), shared.value) { shared.value = null }
                else OnboardingFlow(engine(), state)
            }
        }
        if (engine().state.value.enabled) ConnectionService.start(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        engine().updateForeground(true)
        engine().refreshPermissions(true)
        engine().screenMirror.launchPendingConsent()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && engine().foreground) engine().inspectForegroundClipboard()
    }

    override fun onPause() {
        engine().updateForeground(false)
        super.onPause()
    }

    private fun acceptIntent(intent: Intent?) {
        if (intent == null) return
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        @Suppress("DEPRECATION")
        val uris = when (intent.action) {
            Intent.ACTION_SEND_MULTIPLE -> if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)?.toList() ?: emptyList()
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList() ?: emptyList()
            }
            Intent.ACTION_SEND -> listOfNotNull(if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            })
            else -> emptyList()
        }
        val sourcePackage = referrer?.takeIf { it.scheme == "android-app" }?.host
        val sourceApp = sourcePackage?.let { packageName ->
            runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0)).toString() }.getOrNull()
        }
        if (text != null || uris.isNotEmpty()) shared.value = SharedIntent(text, uris, sourceApp, sourcePackage)
    }
}

/**
 * A user-initiated, translucent activity used by the persistent notification.
 * Android grants clipboard reads while this window has focus, so the user can
 * sync the latest item without opening and navigating through the full app.
 */
class ClipboardCaptureActivity : Activity() {
    private var attempted = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || attempted) return
        attempted = true
        val engine = engine()
        val captured = engine.captureCurrentClipboard()
        val connected = engine.state.value.connections.values.count { it == "Connected" }
        val (title, message) = when {
            !captured -> "Clipboard not synced" to "Copy text, a link, or an image and try again."
            connected == 0 -> "Clipboard saved" to "No Mac is connected right now."
            else -> "Clipboard synced" to "Sent to $connected ${if (connected == 1) "Mac" else "Macs"}."
        }
        ConnectionService.notice(this, title, message)
        finishAndRemoveTask()
    }
}

data class SharedIntent(val text: String?, val files: List<Uri>, val sourceApp: String? = null, val sourcePackage: String? = null)

@androidx.compose.runtime.Composable
internal fun AndroidSyncTheme(content: @androidx.compose.runtime.Composable () -> Unit) {
    val light = lightColorScheme(
        primary = Color(0xFF3B82F6),
        onPrimary = Color.White,
        primaryContainer = Color(0xFFDCEAFF),
        onPrimaryContainer = Color(0xFF0B326B),
        secondary = Color(0xFF1FB6A6),
        onSecondary = Color(0xFF00201C),
        secondaryContainer = Color(0xFFC7F5EF),
        onSecondaryContainer = Color(0xFF003731),
        tertiary = Color(0xFF1FB6A6),
        background = Color(0xFFDFE7EF),
        surface = Color(0xFFDFE7EF),
        surfaceContainer = Color.White,
        surfaceContainerLow = Color(0xFFF4F7FA),
        outlineVariant = Color(0xFFC3CEDA),
        error = Color(0xFFBA1A1A)
    )
    val dark = darkColorScheme(
        primary = Color(0xFF3B82F6),
        onPrimary = Color.White,
        primaryContainer = Color(0xFF0C273B),
        onPrimaryContainer = Color(0xFFDCEAFF),
        secondary = Color(0xFF1FB6A6),
        onSecondary = Color(0xFF001F1C),
        secondaryContainer = Color(0xFF075E56),
        onSecondaryContainer = Color(0xFFC7F5EF),
        tertiary = Color(0xFF1FB6A6),
        background = Color(0xFF001729),
        surface = Color(0xFF001729),
        surfaceContainer = Color(0xFF0C273B),
        surfaceContainerLow = Color(0xFF0C273B),
        outlineVariant = Color(0xFF46505C)
    )
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) dark else light, content = content)
}
