package dev.debugutility.helper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal enum class KeepAliveLeasePhase {
    INACTIVE,
    ACTIVE,
    EXPIRED,
    STOPPED,
    FAILED
}

data class KeepAliveResourceState(
    val notificationVisible: Boolean,
    val wifiLockHeld: Boolean
)

internal data class KeepAliveLeaseStatus(
    val phase: KeepAliveLeasePhase,
    val leaseId: String? = null,
    val startedAtMillis: Long? = null,
    val renewedAtMillis: Long? = null,
    val expiresAtMillis: Long? = null,
    val notificationVisible: Boolean = false,
    val wifiLockHeld: Boolean = false
)

internal fun interface KeepAliveLeaseClock {
    fun nowMillis(): Long
}

internal fun interface KeepAliveLeaseIdGenerator {
    fun next(): String
}

internal interface KeepAliveResources {
    fun acquire(): KeepAliveResourceState
    fun release()
}

internal class KeepAliveLeaseCoordinator(
    private val clock: KeepAliveLeaseClock,
    private val idGenerator: KeepAliveLeaseIdGenerator,
    private val resources: KeepAliveResources,
    private val leaseDurationMillis: Long = LEASE_DURATION_MILLIS
) {
    companion object {
        const val LEASE_DURATION_MILLIS = 30_000L
    }

    private data class ActiveLease(
        val leaseId: String,
        val startedAtMillis: Long,
        val renewedAtMillis: Long,
        val expiresAtMillis: Long,
        val resourceState: KeepAliveResourceState
    )

    private var activeLease: ActiveLease? = null
    private var terminalPhase = KeepAliveLeasePhase.INACTIVE

    @Synchronized
    fun start(): KeepAliveLeaseStatus {
        expireIfNeeded()
        if (activeLease != null) {
            activeLease = null
            resources.release()
        }

        val now = clock.nowMillis()
        val resourceState = try {
            resources.acquire()
        } catch (_: Exception) {
            resources.release()
            terminalPhase = KeepAliveLeasePhase.FAILED
            return terminalStatus()
        }
        if (!resourceState.notificationVisible || !resourceState.wifiLockHeld) {
            resources.release()
            terminalPhase = KeepAliveLeasePhase.FAILED
            return terminalStatus()
        }
        val lease = ActiveLease(
            leaseId = idGenerator.next(),
            startedAtMillis = now,
            renewedAtMillis = now,
            expiresAtMillis = now + leaseDurationMillis,
            resourceState = resourceState
        )
        activeLease = lease
        terminalPhase = KeepAliveLeasePhase.INACTIVE
        return lease.status()
    }

    @Synchronized
    fun renew(leaseId: String): KeepAliveLeaseStatus {
        expireIfNeeded()
        val lease = activeLease ?: return terminalStatus()
        if (lease.leaseId != leaseId) return lease.status()

        val now = clock.nowMillis()
        val renewed = lease.copy(
            renewedAtMillis = now,
            expiresAtMillis = now + leaseDurationMillis
        )
        activeLease = renewed
        return renewed.status()
    }

    @Synchronized
    fun status(): KeepAliveLeaseStatus {
        expireIfNeeded()
        return activeLease?.status() ?: terminalStatus()
    }

    @Synchronized
    fun stop(leaseId: String? = null): KeepAliveLeaseStatus {
        expireIfNeeded()
        val lease = activeLease
        if (lease != null && leaseId != null && lease.leaseId != leaseId) {
            return lease.status()
        }
        if (lease != null) {
            activeLease = null
            resources.release()
        }
        terminalPhase = KeepAliveLeasePhase.STOPPED
        return terminalStatus()
    }

    @Synchronized
    fun shutdown(): KeepAliveLeaseStatus = stop()

    private fun expireIfNeeded() {
        val lease = activeLease ?: return
        if (clock.nowMillis() < lease.expiresAtMillis) return
        activeLease = null
        resources.release()
        terminalPhase = KeepAliveLeasePhase.EXPIRED
    }

    private fun ActiveLease.status() = KeepAliveLeaseStatus(
        phase = KeepAliveLeasePhase.ACTIVE,
        leaseId = leaseId,
        startedAtMillis = startedAtMillis,
        renewedAtMillis = renewedAtMillis,
        expiresAtMillis = expiresAtMillis,
        notificationVisible = resourceState.notificationVisible,
        wifiLockHeld = resourceState.wifiLockHeld
    )

    private fun terminalStatus() = KeepAliveLeaseStatus(phase = terminalPhase)
}

class KeepAliveService : Service(), KeepAliveResources {
    companion object {
        internal const val ACTION_START = "dev.debugutility.helper.keepalive.START"
        internal const val ACTION_RENEW = "dev.debugutility.helper.keepalive.RENEW"
        internal const val ACTION_STOP = "dev.debugutility.helper.keepalive.STOP"
        internal const val ACTION_STATUS = "dev.debugutility.helper.keepalive.STATUS"
        internal const val ACTION_NOTIFICATION_STOP = "dev.debugutility.helper.keepalive.NOTIFICATION_STOP"
        internal const val EXTRA_REQUEST_ID = "request_id"
        internal const val EXTRA_LEASE_ID = "lease_id"

        private const val CHANNEL_ID = "device_bridge_connection"
        private const val NOTIFICATION_ID = 4_201
    }

    private val expiryHandler = Handler(Looper.getMainLooper())
    private val expiryCheck = Runnable { checkExpiry() }
    private lateinit var coordinator: KeepAliveLeaseCoordinator
    private var wifiLock: WifiManager.WifiLock? = null
    private var foregroundStarted = false

    override fun onCreate() {
        super.onCreate()
        coordinator = KeepAliveLeaseCoordinator(
            clock = KeepAliveLeaseClock(System::currentTimeMillis),
            idGenerator = KeepAliveLeaseIdGenerator { UUID.randomUUID().toString() },
            resources = this
        )
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_STATUS
        val leaseId = intent?.getStringExtra(EXTRA_LEASE_ID)
        val status = when (action) {
            ACTION_START -> coordinator.start()
            ACTION_RENEW -> coordinator.renew(leaseId.orEmpty())
            ACTION_STOP, ACTION_NOTIFICATION_STOP -> coordinator.stop(leaseId)
            else -> coordinator.status()
        }

        KeepAliveServiceBroker.complete(intent?.getStringExtra(EXTRA_REQUEST_ID), status)
        if (status.phase == KeepAliveLeasePhase.ACTIVE) {
            scheduleExpiry(status)
        } else {
            expiryHandler.removeCallbacks(expiryCheck)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        expiryHandler.removeCallbacks(expiryCheck)
        coordinator.shutdown()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    override fun acquire(): KeepAliveResourceState {
        val notification = buildNotification()
        startForeground(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        )
        foregroundStarted = true

        val manager = applicationContext.getSystemService(WifiManager::class.java)
        val lock = manager.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            "$packageName:device-bridge"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        wifiLock = lock

        val notifications = getSystemService(NotificationManager::class.java)
        val channelVisible = notifications.getNotificationChannel(CHANNEL_ID)?.importance
            ?.let { it != NotificationManager.IMPORTANCE_NONE }
            ?: false
        return KeepAliveResourceState(
            notificationVisible = notifications.areNotificationsEnabled() && channelVisible,
            wifiLockHeld = lock.isHeld
        )
    }

    override fun release() {
        wifiLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        wifiLock = null
        if (foregroundStarted) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            foregroundStarted = false
        }
    }

    private fun checkExpiry() {
        val status = coordinator.status()
        KeepAliveServiceBroker.publish(status)
        if (status.phase == KeepAliveLeasePhase.ACTIVE) scheduleExpiry(status) else stopSelf()
    }

    private fun scheduleExpiry(status: KeepAliveLeaseStatus) {
        expiryHandler.removeCallbacks(expiryCheck)
        val remaining = (status.expiresAtMillis ?: System.currentTimeMillis()) - System.currentTimeMillis()
        expiryHandler.postDelayed(expiryCheck, remaining.coerceAtLeast(0L))
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_ID,
            "Device Bridge connection maintenance",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Visible while the Mac tool asks Android to keep Wi-Fi awake"
            setShowBadge(false)
        })
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, KeepAliveService::class.java).apply {
            action = ACTION_NOTIFICATION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("Device Bridge is maintaining Wi-Fi")
            .setContentText("Wireless debugging can still stop because of Android or network policy.")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stopPendingIntent).build())
            .build()
    }
}

internal object KeepAliveServiceBroker {
    private data class PendingRequest(
        val latch: CountDownLatch = CountDownLatch(1),
        @Volatile var status: KeepAliveLeaseStatus? = null
    )

    private val pending = ConcurrentHashMap<String, PendingRequest>()
    @Volatile private var latestStatus = KeepAliveLeaseStatus(KeepAliveLeasePhase.INACTIVE)

    fun dispatch(
        context: Context,
        action: String,
        leaseId: String? = null
    ): KeepAliveLeaseStatus? {
        check(Looper.myLooper() != Looper.getMainLooper())
        val requestId = UUID.randomUUID().toString()
        val request = PendingRequest()
        pending[requestId] = request
        val intent = Intent(context, KeepAliveService::class.java).apply {
            this.action = action
            putExtra(KeepAliveService.EXTRA_REQUEST_ID, requestId)
            leaseId?.let { putExtra(KeepAliveService.EXTRA_LEASE_ID, it) }
        }
        try {
            if (action == KeepAliveService.ACTION_START && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (_: RuntimeException) {
            pending.remove(requestId)
            return null
        }
        val completed = try {
            request.latch.await(3, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            false
        }
        pending.remove(requestId)
        return if (completed) request.status else null
    }

    fun complete(requestId: String?, status: KeepAliveLeaseStatus) {
        publish(status)
        if (requestId == null) return
        pending[requestId]?.let { request ->
            request.status = status
            request.latch.countDown()
        }
    }

    fun publish(status: KeepAliveLeaseStatus) {
        latestStatus = status
    }

    fun latest(): KeepAliveLeaseStatus = latestStatus
}

internal class KeepAliveCommandGateway(context: Context) {
    private val applicationContext = context.applicationContext

    fun start(): KeepAliveLeaseStatus? = KeepAliveServiceBroker.dispatch(
        applicationContext,
        KeepAliveService.ACTION_START
    )

    fun renew(leaseId: String): KeepAliveLeaseStatus? = KeepAliveServiceBroker.dispatch(
        applicationContext,
        KeepAliveService.ACTION_RENEW,
        leaseId
    )

    fun stop(leaseId: String? = null): KeepAliveLeaseStatus? = KeepAliveServiceBroker.dispatch(
        applicationContext,
        KeepAliveService.ACTION_STOP,
        leaseId
    )

    fun status(): KeepAliveLeaseStatus? = KeepAliveServiceBroker.dispatch(
        applicationContext,
        KeepAliveService.ACTION_STATUS
    )
}
