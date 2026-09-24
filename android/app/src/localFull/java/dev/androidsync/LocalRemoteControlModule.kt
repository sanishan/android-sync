package dev.androidsync

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Path
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

internal fun platformRemoteControlModule(engine: SyncEngine): RemoteControlModule = LocalRemoteControlModule(engine)

private class LocalRemoteControlModule(private val engine: SyncEngine) : RemoteControlModule {
    override val enabled: Boolean get() = AndroidSyncAccessibilityService.current != null
    override fun refresh() = Unit
    override fun execute(command: Wire): Pair<Boolean,String> {
        val service = AndroidSyncAccessibilityService.current ?: return false to "Enable Android Sync remote control in Accessibility settings."
        return service.execute(command)
    }
}

class AndroidSyncAccessibilityService : AccessibilityService() {
    companion object { @Volatile var current: AndroidSyncAccessibilityService? = null }

    override fun onServiceConnected() { current = this; applicationContext.engine().refreshPermissions() }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit
    override fun onDestroy() { if (current === this) current = null; applicationContext.engine().refreshPermissions(); super.onDestroy() }

    fun execute(command: Wire): Pair<Boolean,String> = runCatching {
        when (command.body.getString("action")) {
            "tap" -> gesture(command, false)
            "swipe" -> gesture(command, true)
            "back" -> require(performGlobalAction(GLOBAL_ACTION_BACK)) { "Android rejected Back." }
            "home" -> require(performGlobalAction(GLOBAL_ACTION_HOME)) { "Android rejected Home." }
            "recents" -> require(performGlobalAction(GLOBAL_ACTION_RECENTS)) { "Android rejected Recents." }
            "notifications" -> require(performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)) { "Android rejected Notifications." }
            "text" -> setText(command.body.getString("text"))
            "paste" -> paste(command.body.getString("text"))
            else -> error("Unsupported remote-control action.")
        }
        true to "Accepted by Android Accessibility."
    }.getOrElse { false to (it.message ?: "Android rejected the remote-control action.") }

    private fun gesture(command: Wire, swipe: Boolean) {
        val metrics = resources.displayMetrics
        fun coordinate(key: String, extent: Int): Float = (command.body.optDouble(key).coerceIn(0.0,1.0) * extent).toFloat()
        val path = Path().apply {
            moveTo(coordinate("x",metrics.widthPixels),coordinate("y",metrics.heightPixels))
            if (swipe) lineTo(coordinate("endX",metrics.widthPixels),coordinate("endY",metrics.heightPixels))
        }
        val duration = if (swipe) command.body.optLong("duration",300).coerceIn(80,2_000) else 80
        val description = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path,0,duration)).build()
        require(dispatchGesture(description,null,null)) { "Android could not dispatch the gesture." }
    }

    private fun editableNode(): AccessibilityNodeInfo {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: error("Focus an editable field on Android first.")
        require(node.isEditable && !node.isPassword) { "Text insertion is unavailable for secure or non-editable fields." }
        return node
    }

    private fun setText(text: String) {
        require(text.length <= 10_000) { "Text is limited to 10,000 characters." }
        val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,text) }
        require(editableNode().performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,args)) { "This field does not support text insertion." }
    }

    private fun paste(text: String) {
        require(text.length <= 64 * 1024) { "Paste text is limited to 64 KiB." }
        val node = editableNode()
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Android Sync remote paste",text))
        require(node.performAction(AccessibilityNodeInfo.ACTION_PASTE)) { "This field does not support paste." }
    }
}
