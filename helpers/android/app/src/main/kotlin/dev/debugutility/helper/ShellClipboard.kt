package dev.debugutility.helper

import android.content.ClipData
import android.os.IBinder
import org.json.JSONObject
import java.lang.reflect.InvocationTargetException
import java.time.Instant

/** Short-lived adb app_process entry. No Activity, UI, socket, history or persistent process.
 * Uses the shell caller identity, as in scrcpy; hidden Binder API versions are an explicit boundary.
 * https://github.com/Genymobile/scrcpy (Apache-2.0), server clipboard wrappers.
 */
object ShellClipboard {
    @JvmStatic fun main(args: Array<String>) {
        Thread({ Thread.sleep(15_000); kotlin.system.exitProcess(124) }, "clipboard-deadline")
            .apply { isDaemon = true; start() }
        var requestId = ""
        val response = try {
            val bytes = FrameCodec.read(java.io.DataInputStream(System.`in`))
            val request = JSONObject(bytes.toString(Charsets.UTF_8))
            requestId = request.getString("requestId")
            require(android.os.Process.myUid() in setOf(0, 2000)) { "shell.required" }
            // Rooted emulators start adb commands as root. Clipboard attributes access to the
            // shell package, so drop to its UID before Binder access (never elevate permissions).
            if (android.os.Process.myUid() == 0) {
                android.system.Os.setgid(2000)
                android.system.Os.setuid(2000)
            }
            require(requestId.isNotEmpty() && request.getInt("protocolVersion") == 1)
            val now = Instant.now()
            val created = Instant.parse(request.getString("createdAt"))
            val expires = Instant.parse(request.getString("expiresAt"))
            require(!created.isAfter(expires) && !created.isAfter(now.plusSeconds(120)) && expires.isAfter(now)) { "request.expired" }
            // Check the physical device inside the same process that accesses content, before access.
            val expected = request.getString("helperDeviceId")
            val actual = if (expected.startsWith("android:boot:")) {
                "android:boot:" + java.io.File("/proc/sys/kernel/random/boot_id").readText().trim().lowercase()
            } else {
                val serial = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                    .invoke(null, "ro.serialno") as String
                "android:hardware:$serial"
            }
            require(expected == actual) { "identity.mismatch" }
            val clipboard = ShellClipboardAccess()
            val payload = when (request.getString("action")) {
                "clipboard.read" -> JSONObject().put("text", clipboard.readText())
                "clipboard.write" -> {
                    val text = request.getJSONObject("payload").getString("text")
                    require(ClipboardText.fits(text)) { "clipboard.too_large" }
                    clipboard.writeText(text)
                    check(clipboard.readText() == text) { "clipboard.write_unverified" }
                    JSONObject().put("written", true)
                }
                else -> throw IllegalArgumentException("action.unsupported")
            }
            result(requestId, "success").put("payload", payload)
        } catch (error: Throwable) {
            val cause = if (error is InvocationTargetException) error.targetException else error
            // Diagnostics contain types/frames only, never exception messages or clipboard content.
            System.err.println("DeviceBridge clipboard: ${cause.javaClass.name}")
            cause.stackTrace.take(4).forEach { System.err.println("  at $it") }
            val denied = cause is SecurityException
            result(requestId, if (denied) "permissionDenied" else "failure").put("error", JSONObject()
                .put("code", if (denied) "clipboard.denied" else "clipboard.unavailable")
                .put("message", if (denied) "Android denied background clipboard access."
                    else "Background clipboard access failed or no readable text is available.")
                .put("recoveryAction", "Unlock the device, copy plain text, and retry. No helper app will be opened."))
        }
        System.out.print(response.toString())
        System.out.flush()
        kotlin.system.exitProcess(0)
    }

    private fun result(id: String, status: String) = JSONObject().put("protocolVersion", 1)
        .put("requestId", id).put("status", status).put("completedAt", Instant.now().toString())
}

internal class ShellClipboardAccess {
    private val service: Any
    private val get: java.lang.reflect.Method
    private val set: java.lang.reflect.Method
    private val readCaller: Array<Any?>
    private val writeCaller: Array<Any?>

    init {
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "clipboard") as IBinder
        service = Class.forName("android.content.IClipboard\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
        val user = Class.forName("android.app.ActivityManager").getMethod("getCurrentUser").invoke(null) as Int
        // Getter/setter signatures can differ on OEM systems. Match known contracts independently;
        // never invent arguments for an unknown method. These variants are documented by scrcpy.
        fun resolve(name: String, writing: Boolean): Pair<java.lang.reflect.Method, Array<Any?>> {
            val s = String::class.java
            val i = Int::class.javaPrimitiveType!!
            val b = Boolean::class.javaPrimitiveType!!
            val standard = listOf(
                arrayOf(s, s, i, i) to arrayOf<Any?>("com.android.shell", null, user, 0),
                arrayOf(s, s, i) to arrayOf<Any?>("com.android.shell", null, user),
                arrayOf(s, i) to arrayOf<Any?>("com.android.shell", user),
                arrayOf(s, s, i, i, b) to arrayOf<Any?>("com.android.shell", null, user, 0, true)
            )
            val variants = if (writing) standard else standard + listOf(
                arrayOf(s, i, s) to arrayOf<Any?>("com.android.shell", user, null),
                arrayOf(s, s, s, s, i, i, b) to arrayOf<Any?>("com.android.shell", null, null, null, user, 0, true),
                arrayOf(s, s, i, i, s) to arrayOf<Any?>("com.android.shell", null, user, 0, null)
            )
            for ((types, arguments) in variants) {
                val parameters = if (writing) arrayOf(ClipData::class.java, *types) else types
                val method = runCatching { service.javaClass.getMethod(name, *parameters) }.getOrNull()
                if (method != null) return method to arguments
            }
            throw NoSuchMethodException(name)
        }
        val read = resolve("getPrimaryClip", false)
        val write = resolve("setPrimaryClip", true)
        get = read.first; readCaller = read.second
        set = write.first; writeCaller = write.second
    }

    fun readText(): String {
        val clip = get.invoke(service, *readCaller) as? ClipData ?: error("clipboard.unavailable")
        return when (val value = ClipboardText.read((0 until clip.itemCount).asSequence().map { clip.getItemAt(it).text })) {
            is ClipboardReadValue.Text -> value.value
            ClipboardReadValue.Unavailable -> error("clipboard.unavailable")
        }
    }

    fun writeText(text: String) {
        set.invoke(service, ClipData.newPlainText("Device Bridge", text), *writeCaller)
    }
}
