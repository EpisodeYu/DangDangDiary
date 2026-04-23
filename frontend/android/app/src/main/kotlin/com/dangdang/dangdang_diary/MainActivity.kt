package com.dangdang.dangdang_diary

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    /**
     * Fires only when the user explicitly leaves our task (Home button,
     * recents, switching to another app). We intentionally *don't* start the
     * keep-alive service from `onPause` / `onStop`, because those also run
     * when a system dialog or photo picker takes the foreground — in those
     * cases the app is about to come back on its own and a persistent
     * notification would be annoying.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        val intent = Intent(this, BackgroundKeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            @Suppress("DEPRECATION")
            startService(intent)
        }
    }

    override fun onResume() {
        super.onResume()
        stopService(Intent(this, BackgroundKeepAliveService::class.java))
    }
}
