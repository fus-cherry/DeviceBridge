package dev.debugutility.helper

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

class FrameCodecTest {
    @Test
    fun `maximum clipboard escaped JSON fits the frame without truncation`() {
        val payload = ("{\"text\":\"" + "\\u0000".repeat(1_048_576) + "\"}").toByteArray(Charsets.UTF_8)
        val bytes = ByteArrayOutputStream().also { FrameCodec.write(DataOutputStream(it), payload) }.toByteArray()
        assertArrayEquals(payload, FrameCodec.read(DataInputStream(ByteArrayInputStream(bytes))))
    }

    @Test
    fun `write uses a big-endian length prefix and round trips unicode`() {
        val payload = "设备剪切板 📋".toByteArray(Charsets.UTF_8)
        val bytes = ByteArrayOutputStream().also { stream ->
            FrameCodec.write(DataOutputStream(stream), payload)
        }.toByteArray()

        assertEquals(payload.size, DataInputStream(ByteArrayInputStream(bytes)).readInt())
        assertArrayEquals(
            payload,
            FrameCodec.read(DataInputStream(ByteArrayInputStream(bytes)))
        )
    }

    @Test
    fun `read rejects frames above the protocol limit before allocating payload`() {
        val bytes = ByteArrayOutputStream().also { stream ->
            DataOutputStream(stream).writeInt(ClipboardBridge.MAX_ENVELOPE_BYTES + 1)
        }.toByteArray()

        assertThrows(IllegalArgumentException::class.java) {
            FrameCodec.read(DataInputStream(ByteArrayInputStream(bytes)))
        }
    }

    @Test
    fun `write rejects payloads above the protocol limit`() {
        val oversized = ByteArray(ClipboardBridge.MAX_ENVELOPE_BYTES + 1)

        assertThrows(IllegalArgumentException::class.java) {
            FrameCodec.write(DataOutputStream(ByteArrayOutputStream()), oversized)
        }
    }
}
