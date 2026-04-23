package com.dangdang.dangdang_diary

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * Short-lived foreground service that keeps the Flutter process alive for a
 * bounded window after the user presses Home, so returning to the app
 * restores state instantly instead of triggering a cold start.
 *
 * Lifecycle contract:
 *   * `MainActivity.onUserLeaveHint()` schedules us via `startForegroundService`.
 *   * `MainActivity.onResume()` stops us immediately — quick task-switches
 *     therefore don't leave a lingering notification.
 *   * If the user never comes back within [KEEP_ALIVE_MILLIS], we stop
 *     ourselves and let the OS reclaim the process normally.
 */
class BackgroundKeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "dangdang_keep_alive"
        private const val NOTIFICATION_ID = 0xDDD1
        // Keep the process warm for up to 10 minutes after the user minimises
        // the app. Longer windows annoy the user with a persistent
        // notification; shorter windows defeat the point of surviving a brief
        // task-switch.
        private const val KEEP_ALIVE_MILLIS = 10L * 60L * 1000L
    }

    private var stopHandler: Handler? = null
    private var stopRunnable: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        scheduleStop()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        cancelStop()
        super.onDestroy()
    }

    private fun scheduleStop() {
        cancelStop()
        val handler = Handler(Looper.getMainLooper())
        val runnable = Runnable { stopSelf() }
        stopHandler = handler
        stopRunnable = runnable
        handler.postDelayed(runnable, KEEP_ALIVE_MILLIS)
    }

    private fun cancelStop() {
        stopRunnable?.let { r -> stopHandler?.removeCallbacks(r) }
        stopHandler = null
        stopRunnable = null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.keep_alive_channel_name),
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = getString(R.string.keep_alive_channel_description)
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
            lockscreenVisibility = Notification.VISIBILITY_SECRET
        }
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPi = launchIntent?.let {
            PendingIntent.getActivity(this, 0, it, pendingFlags)
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.keep_alive_notification_title))
            .setContentText(getString(R.string.keep_alive_notification_text))
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setContentIntent(contentPi)
            .build()
    }
}
