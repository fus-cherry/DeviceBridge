package dev.debugutility.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.FutureTask

class ClipboardTextTest {
    @Test
    fun `main thread task preserves typed clipboard failures for safe mapping`() {
        val oversized = FutureTask(Callable<String> { throw ClipboardText.TooLarge() })
        oversized.run()
        assertThrows(ClipboardText.TooLarge::class.java) { clipboardTaskResult(oversized) }
        val denied = FutureTask(Callable<String> { throw SecurityException() })
        denied.run()
        assertThrows(SecurityException::class.java) { clipboardTaskResult(denied) }
    }

    @Test
    fun `current text items are joined in order and retain empty items`() {
        assertEquals("first\n\n设备 📋\nlast", ClipboardText.join(sequenceOf("first", null, "", "设备 📋", "last")))
    }

    @Test
    fun `text beyond the old character limit remains complete`() {
        val text = "你\n".repeat(200_000) + "END"
        assertEquals(text, ClipboardText.join(sequenceOf(text)))
    }

    @Test
    fun `limit counts UTF8 bytes and join separators without truncation`() {
        assertEquals("a".repeat(1_048_576), ClipboardText.join(sequenceOf("a".repeat(1_048_576))))
        assertThrows(ClipboardText.TooLarge::class.java) {
            ClipboardText.join(sequenceOf("你".repeat(349_526)))
        }
        assertThrows(ClipboardText.TooLarge::class.java) {
            ClipboardText.join(sequenceOf("a".repeat(1_048_576), ""))
        }
    }

    @Test
    fun `oversized item stops consumption before later clipboard items`() {
        var reachedLaterItem = false
        val items = sequence {
            yield("a".repeat(1_048_577))
            reachedLaterItem = true
            yield("later")
        }
        assertThrows(ClipboardText.TooLarge::class.java) { ClipboardText.join(items) }
        assertEquals(false, reachedLaterItem)
    }
}
