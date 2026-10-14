package dev.debugutility.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ClipboardTextTest {
    @Test
    fun `current text items are joined in order and retain empty items`() {
        assertEquals("first\n\n设备 📋\nlast", ClipboardText.join(sequenceOf("first", null, "", "设备 📋", "last")))
    }

    @Test
    fun `missing or unreadable clipboard differs from an explicit empty text item`() {
        assertEquals(ClipboardReadValue.Unavailable, ClipboardText.read(sequenceOf()))
        assertEquals(ClipboardReadValue.Unavailable, ClipboardText.read(sequenceOf(null)))
        assertEquals(ClipboardReadValue.Text(""), ClipboardText.read(sequenceOf("")))
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
