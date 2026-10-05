package app.omniplay.omniplay

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.omniplay/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepAwake" -> {
                        val active = call.arguments as? Boolean ?: false
                        runOnUiThread {
                            if (active) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    "startNodeService" -> {
                        startForegroundService(Intent(this, NodeService::class.java))
                        result.success(null)
                    }
                    "stopNodeService" -> {
                        stopService(Intent(this, NodeService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        // UDP 广播信标接收需要多播锁（部分机型 Wi-Fi 下广播默认被过滤）。
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("omniplay-beacon").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onPause() {
        multicastLock?.release()
        multicastLock = null
        super.onPause()
    }
}
