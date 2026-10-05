package app.omniplay.omniplay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/// 节点前台服务（M0-β）：常驻通知保活，避免 MIUI/系统冻结后节点网络死亡。
class NodeService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    "omniplay_node",
                    "OmniPlay 节点服务",
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, "omniplay_node")
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val notification: Notification = builder
            .setContentTitle("OmniPlay 节点运行中")
            .setContentText("局域网内可发现并控制本设备")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
        startForeground(1, notification)
    }
}
