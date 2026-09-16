package dev.debugutility.helper

internal sealed interface ClipboardReadValue {
    data object Unavailable : ClipboardReadValue
    data class Text(val value: String) : ClipboardReadValue
}

/** Complete current plain text only; never opens clipboard URI providers or retains history. */
internal object ClipboardText {
    const val MAX_UTF8_BYTES = 1_048_576
    class TooLarge : Exception()

    fun fits(text: CharSequence, remainingBytes: Int = MAX_UTF8_BYTES): Boolean {
        // Reject before conversion: no item larger than the budget is copied or encoded.
        if (text.length > remainingBytes) return false
        return text.toString().toByteArray(Charsets.UTF_8).size <= remainingBytes
    }

    fun read(items: Sequence<CharSequence?>): ClipboardReadValue {
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
        return if (hasText) ClipboardReadValue.Text(result.toString()) else ClipboardReadValue.Unavailable
    }

    fun join(items: Sequence<CharSequence?>): String {
        return when (val value = read(items)) {
            ClipboardReadValue.Unavailable -> ""
            is ClipboardReadValue.Text -> value.value
        }
    }
}
