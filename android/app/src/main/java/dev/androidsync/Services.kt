package dev.androidsync

import android.app.*
import android.content.*
import android.os.IBinder

class ConnectionService : Service() {
    companion object {
        fun start(context: Context) { runCatching { context.startForegroundService(Intent(context,ConnectionService::class.java)) }.onFailure { context.engine().fail("Open Android Sync to resume the connection service.") } }
        fun notice(context: Context, title: String, text: String) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel("events","Shared content",NotificationManager.IMPORTANCE_DEFAULT))
            val open = PendingIntent.getActivity(context,0,Intent(context,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            runCatching { manager.notify((System.nanoTime() and 0x7fffffff).toInt(),Notification.Builder(context,"events").setSmallIcon(R.drawable.ic_sync).setContentTitle(title).setContentText(text).setContentIntent(open).setAutoCancel(true).build()) }
        }
    }
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("connection","Device connection",NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this,1,Intent(this,ConnectionService::class.java).setAction("STOP"),PendingIntent.FLAG_IMMUTABLE)
        val captureIntent = Intent(this,ClipboardCaptureActivity::class.java)
            .setAction("dev.androidsync.CAPTURE_CLIPBOARD")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        val capture = PendingIntent.getActivity(this,2,captureIntent,PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(1,Notification.Builder(this,"connection")
            .setSmallIcon(R.drawable.ic_sync)
            .setContentTitle("Android Sync is running")
            .setContentText("Connections active · clipboard syncs while the app is open")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null,"Sync clipboard",capture).build())
            .addAction(Notification.Action.Builder(null,"Pause connections",stop).build())
            .build(),android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") { engine().setEnabled(false); stopSelf(); return START_NOT_STICKY }
        if (engine().state.value.enabled) engine().startConnections() else stopSelf()
        return START_STICKY
    }
    override fun onDestroy() { engine().stopConnections(); super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
}
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED) &&
            context.engine().state.value.enabled
        ) ConnectionService.start(context)
    }
}
