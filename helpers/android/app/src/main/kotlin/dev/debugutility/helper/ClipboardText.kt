package dev.debugutility.helper

/** Complete current plain text only; never opens clipboard URI providers or retains history. */
internal object ClipboardText {
    const val MAX_UTF8_BYTES = 1_048_576
    class TooLarge : Exception()

    fun fits(text: CharSequence, remainingBytes: Int = MAX_UTF8_BYTES): Boolean {
        // Reject before conversion: no item larger than the budget is copied or encoded.
        if (text.length > remainingBytes) return false
        return text.toString().toByteArray(Charsets.UTF_8).size <= remainingBytes
    }

    fun join(items: Sequence<CharSequence?>): String {
        val result = StringBuilder()
        var usedBytes = 0
        var hasText = false
        for (item in items) {
            if (item == null) continue
            val separatorBytes = if (hasText) 1 else 0
            val remainingBytes = MAX_UTF8_BYTES - usedBytes - separatorBytes
            if (!fits(item, remainingBytes)) throw TooLarge()
            val text = item.toString()
            if (hasText) result.append('\n')
            result.append(text)
            usedBytes += separatorBytes + text.toByteArray(Charsets.UTF_8).size
            hasText = true
        }
        return result.toString()
    }
}
