package dev.debugutility.helper

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.atomic.AtomicBoolean

class ClipboardBridge(private val context: Context) : AutoCloseable {
    companion object {
        const val SOCKET_NAME = "device_bridge_helper"
        const val MAX_ENVELOPE_BYTES = 6 * ClipboardText.MAX_UTF8_BYTES + 64 * 1024
    }

    private val running = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val keepAlive = KeepAliveCommandGateway(context)
    private val completedRequestIds = mutableSetOf<String>()
    private val helperDeviceId: String by lazy {
        val preferences = context.getSharedPreferences("device_bridge_identity", Context.MODE_PRIVATE)
        preferences.getString("helper_device_id", null) ?: UUID.randomUUID().toString().also {
            preferences.edit().putString("helper_device_id", it).apply()
        }
    }
    private var sessionNonce: String? = null
    private var serverSocket: LocalServerSocket? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        executor.execute {
            try {
                LocalServerSocket(SOCKET_NAME).also { server ->
                    serverSocket = server
                    while (running.get()) {
                        val socket = try {
                            server.accept()
                        } catch (_: Exception) {
                            if (!running.get()) break else continue
                        }
                        socket.use(::serve)
                    }
                }
            } finally {
                running.set(false)
                serverSocket = null
            }
        }
    }

    override fun close() {
        running.set(false)
        runCatching { serverSocket?.close() }
        executor.shutdownNow()
        sessionNonce = null
        completedRequestIds.clear()
    }

    private fun serve(socket: LocalSocket) {
        val input = DataInputStream(socket.inputStream)
        val output = DataOutputStream(socket.outputStream)
        while (running.get()) {
            val payload = try {
                FrameCodec.read(input)
            } catch (_: Exception) {
                break
            }
            val response = handle(payload)
            try {
                FrameCodec.write(output, response)
            } catch (_: Exception) {
                break
            }
        }
    }

    private fun handle(bytes: ByteArray): ByteArray {
        if (bytes.size > MAX_ENVELOPE_BYTES) return invalidResult("", "envelope.too_large")
        val request = try {
            JSONObject(bytes.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            return invalidResult("", "envelope.invalid_json")
        }
        val requestId = request.optString("requestId")
        val validationError = validate(request)
        if (validationError != null) return invalidResult(requestId, validationError)

        val action = request.getString("action")
        val result = when (action) {
            "identity" -> identityResult(requestId)
            "clipboard.read" -> readClipboard(requestId)
            "clipboard.write" -> writeClipboard(requestId, request.optJSONObject("payload"))
            "keepAlive.start" -> startKeepAlive(requestId)
            "keepAlive.renew" -> renewKeepAlive(requestId, request.optJSONObject("payload"))
            "keepAlive.stop" -> stopKeepAlive(requestId, request.optJSONObject("payload"))
            "keepAlive.status" -> statusKeepAlive(requestId)
            "stop" -> {
                keepAlive.stop()
                successResult(requestId, JSONObject().put("stopped", true))
            }
            else -> invalidResult(requestId, "action.unsupported")
        }
        completedRequestIds += requestId
        return result
    }

    private fun validate(request: JSONObject): String? {
        if (request.optInt("protocolVersion", -1) != 1) return "protocol.unsupported"
        val requestId = request.optString("requestId")
        if (requestId.isBlank()) return "request.missing_id"
        if (requestId in completedRequestIds) return "request.replayed"
        val action = request.optString("action")
        if (action !in setOf(
                "identity",
                "clipboard.read",
                "clipboard.write",
                "keepAlive.start",
                "keepAlive.renew",
                "keepAlive.stop",
                "keepAlive.status",
                "stop"
            )) {
            return "action.unsupported"
        }
        val createdAt = runCatching { Instant.parse(request.getString("createdAt")) }.getOrNull()
            ?: return "request.invalid_time"
        val expiresAt = runCatching { Instant.parse(request.getString("expiresAt")) }.getOrNull()
            ?: return "request.invalid_time"
        val now = Instant.now()
        if (createdAt.isAfter(expiresAt) || createdAt.isAfter(now.plusSeconds(120))) {
            return "request.invalid_time"
        }
        if (expiresAt.isBefore(now)) return "request.expired"

        val nonce = request.optString("sessionNonce")
        val requestDeviceId = request.optString("helperDeviceId")
        if (action == "identity" && sessionNonce == null && requestDeviceId == "bootstrap") {
            if (nonce.isBlank()) return "session.invalid_nonce"
            sessionNonce = nonce
            return null
        }
        if (nonce != sessionNonce) return "session.invalid_nonce"
        if (requestDeviceId != helperDeviceId) return "identity.mismatch"
        return null
    }

    private fun identityResult(requestId: String): ByteArray = successResult(
        requestId,
        JSONObject()
            .put("helperDeviceId", helperDeviceId)
            .put("helperVersion", "0.3.0")
            .put("protocolVersions", JSONArray().put(1))
            .put(
                "actions",
                JSONArray()
                    .put("identity")
                    .put("clipboard.read")
                    .put("clipboard.write")
                    .put("keepAlive.start")
                    .put("keepAlive.renew")
                    .put("keepAlive.stop")
                    .put("keepAlive.status")
                    .put("stop")
            )
    )

    private fun startKeepAlive(requestId: String): ByteArray {
        val status = keepAlive.start()
            ?: return errorResult(
                requestId,
                "failure",
                "keepalive.start_timeout",
                "Android did not start connection maintenance in time."
            )
        if (status.phase == KeepAliveLeasePhase.FAILED) {
            return errorResult(
                requestId,
                "actionRequired",
                "keepalive.notification_required",
                "Enable helper notifications before starting Wi-Fi maintenance.",
                "Allow notifications for Device Bridge Helper, then retry."
            )
        }
        return keepAliveResult(requestId, status)
    }

    private fun renewKeepAlive(requestId: String, payload: JSONObject?): ByteArray {
        val leaseId = payload?.takeIf { it.has("leaseId") }?.getString("leaseId")
            ?: return invalidResult(requestId, "keepalive.missing_lease")
        val status = keepAlive.renew(leaseId)
            ?: return errorResult(
                requestId,
                "failure",
                "keepalive.renew_timeout",
                "Android did not renew connection maintenance in time."
            )
        return when {
            status.phase == KeepAliveLeasePhase.EXPIRED -> errorResult(
                requestId,
                "expired",
                "keepalive.expired",
                "The connection-maintenance lease expired."
            )
            status.phase != KeepAliveLeasePhase.ACTIVE || status.leaseId != leaseId ->
                invalidResult(requestId, "keepalive.lease_mismatch")
            else -> keepAliveResult(requestId, status)
        }
    }

    private fun stopKeepAlive(requestId: String, payload: JSONObject?): ByteArray {
        val leaseId = payload?.takeIf { it.has("leaseId") }?.getString("leaseId")
        val status = keepAlive.stop(leaseId)
            ?: return errorResult(
                requestId,
                "failure",
                "keepalive.stop_timeout",
                "Android did not stop connection maintenance in time."
            )
        if (status.phase == KeepAliveLeasePhase.ACTIVE) {
            return invalidResult(requestId, "keepalive.lease_mismatch")
        }
        return keepAliveResult(requestId, status)
    }

    private fun statusKeepAlive(requestId: String): ByteArray {
        val status = keepAlive.status()
            ?: return errorResult(
                requestId,
                "failure",
                "keepalive.status_timeout",
                "Android did not report connection-maintenance status in time."
            )
        return keepAliveResult(requestId, status)
    }

    private fun keepAliveResult(requestId: String, status: KeepAliveLeaseStatus): ByteArray {
        val payload = JSONObject()
            .put("state", status.phase.name.lowercase())
            .put("notificationVisible", status.notificationVisible)
            .put("wifiLockHeld", status.wifiLockHeld)
        status.leaseId?.let { payload.put("leaseId", it) }
        status.startedAtMillis?.let { payload.put("startedAt", Instant.ofEpochMilli(it).toString()) }
        status.renewedAtMillis?.let { payload.put("renewedAt", Instant.ofEpochMilli(it).toString()) }
        status.expiresAtMillis?.let { payload.put("expiresAt", Instant.ofEpochMilli(it).toString()) }
        return successResult(requestId, payload)
    }

    private fun readClipboard(requestId: String): ByteArray = try {
        val value = onMainThread {
            val manager = context.getSystemService(ClipboardManager::class.java)
            val clip = manager.primaryClip
            if (clip == null) ClipboardReadValue.Unavailable
            else ClipboardText.read((0 until clip.itemCount).asSequence().map { clip.getItemAt(it).text })
        }
        when (value) {
            ClipboardReadValue.Unavailable -> errorResult(
                requestId,
                "actionRequired",
                "clipboard.unavailable",
                "No readable text is currently available.",
                "Copy text on the device, keep the helper visible, and retry."
            )
            is ClipboardReadValue.Text -> successResult(requestId, JSONObject().put("text", value.value))
        }
    } catch (_: ClipboardText.TooLarge) {
        errorResult(requestId, "failure", "clipboard.too_large", "Clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated or transferred.")
    } catch (_: SecurityException) {
        errorResult(
            requestId,
            "permissionDenied",
            "clipboard.denied",
            "Clipboard access requires the helper to remain visible."
        )
    } catch (_: Exception) {
        errorResult(requestId, "failure", "clipboard.read_failed", "Clipboard text could not be read.")
    }

    private fun writeClipboard(requestId: String, payload: JSONObject?): ByteArray {
        val text = payload?.takeIf { it.has("text") }?.getString("text")
            ?: return invalidResult(requestId, "clipboard.missing_text")
        if (!ClipboardText.fits(text)) {
            return invalidResult(requestId, "clipboard.too_large")
        }
        return try {
            val verified = onMainThread {
                val manager = context.getSystemService(ClipboardManager::class.java)
                manager.setPrimaryClip(ClipData.newPlainText("Device Bridge", text))
                val clip = manager.primaryClip
                val current = if (clip == null) ClipboardReadValue.Unavailable
                    else ClipboardText.read((0 until clip.itemCount).asSequence().map { clip.getItemAt(it).text })
                current == ClipboardReadValue.Text(text)
            }
            if (verified) {
                successResult(requestId, JSONObject().put("written", true))
            } else {
                errorResult(
                    requestId,
                    "actionRequired",
                    "clipboard.write_unverified",
                    "Android did not confirm the clipboard write.",
                    "Keep the helper visible and retry."
                )
            }
        } catch (_: SecurityException) {
            errorResult(requestId, "permissionDenied", "clipboard.denied", "Clipboard access was denied.")
        } catch (_: Exception) {
            errorResult(requestId, "failure", "clipboard.write_failed", "Clipboard text could not be written.")
        }
    }

    private fun successResult(requestId: String, payload: JSONObject): ByteArray = JSONObject()
        .put("protocolVersion", 1)
        .put("requestId", requestId)
        .put("status", "success")
        .put("completedAt", Instant.now().toString())
        .put("payload", payload)
        .toString()
        .toByteArray(Charsets.UTF_8)

    private fun invalidResult(requestId: String, code: String): ByteArray = errorResult(
        requestId,
        "invalid",
        code,
        "The helper request was invalid."
    )

    private fun errorResult(
        requestId: String,
        status: String,
        code: String,
        message: String,
        recoveryAction: String? = null
    ): ByteArray = JSONObject()
            .put("protocolVersion", 1)
            .put("requestId", requestId)
            .put("status", status)
            .put("completedAt", Instant.now().toString())
            .put(
                "error",
                JSONObject()
                    .put("code", code)
                    .put("message", message)
                    .also { error -> recoveryAction?.let { error.put("recoveryAction", it) } }
            )
            .toString()
            .toByteArray(Charsets.UTF_8)

    private fun <T> onMainThread(callable: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return callable()
        val task = FutureTask(Callable(callable))
        mainHandler.post(task)
        return clipboardTaskResult(task)
    }
}

internal fun <T> clipboardTaskResult(task: FutureTask<T>): T = try {
    task.get()
} catch (error: ExecutionException) {
    throw error.cause ?: error
}

internal object FrameCodec {
    fun read(input: DataInputStream): ByteArray {
        val length = input.readInt()
        require(length in 0..ClipboardBridge.MAX_ENVELOPE_BYTES)
        return ByteArray(length).also(input::readFully)
    }

    fun write(output: DataOutputStream, payload: ByteArray) {
        require(payload.size <= ClipboardBridge.MAX_ENVELOPE_BYTES)
        output.writeInt(payload.size)
        output.write(payload)
        output.flush()
    }
}
