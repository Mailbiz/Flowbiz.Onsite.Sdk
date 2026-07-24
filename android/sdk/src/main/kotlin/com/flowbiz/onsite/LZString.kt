package com.flowbiz.onsite

/**
 * Native port of LZ-string 1.4.4 `decompressFromEncodedURIComponent`
 * (SPEC §11) — decompress only; the SDK never compresses.
 *
 * Ported line-for-line from the reference JS (`libs/lz-string.js`,
 * Pieroxy, WTFPL), including its quirks:
 *
 * - the URI-safe alphabet `A-Za-z0-9+-$`;
 * - the `" "` → `"+"` restoration (naive URL decoding turns the `+` output
 *   character into a space; the reference restores it before decoding);
 * - a character outside the alphabet contributes 0-bits (JS reads
 *   `undefined` from the reverse dictionary and `NaN & x === 0`) — garbage
 *   input degrades to garbage/empty output, never a throw;
 * - reading past the end of input yields 0-bits (JS `charAt` → `""` →
 *   `undefined`), while the symbol loop's own bounds check returns `""`;
 * - an invalid dictionary index returns null (reference `return null`).
 *
 * Deviations (documented, garbage-input-only):
 * - JS returns `""` for a *null* input and `null` for `""`; the Kotlin
 *   signature folds both to null (nil-in → nil-out is the idiomatic port).
 * - A first 2-bit token of 3 is impossible in real compressed output (the
 *   compressor emits 0/1/2 first); on such input the reference library
 *   returns `""` or throws a `TypeError` (reading a property of the
 *   `undefined` first entry), and the web tracker's wrapper masks the throw
 *   to `''` — this port returns null instead: safer and unambiguous
 *   (pinned by the shared `garbage_first_token_3` vector).
 *
 * Behavior is pinned against the real JS library by
 * `shared/lzstring-vectors/vectors.json` (vectors generated with lz-string
 * 1.4.4 under node; garbage-case expectations are the library's actual
 * outputs, including its `""` results). Never throws.
 */
internal object LZString {

    private const val KEY_STR_URI_SAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-\$"

    /** Char code → alphabet value; -1 for characters outside the alphabet. */
    private val reverseUriSafe = IntArray(128) { -1 }.also { table ->
        KEY_STR_URI_SAFE.forEachIndexed { value, char -> table[char.code] = value }
    }

    fun decompressFromEncodedURIComponent(input: String?): String? {
        if (input.isNullOrEmpty()) return null
        val restored = input.replace(' ', '+')
        return decompress(restored.length, 32) { index ->
            if (index >= restored.length) {
                0
            } else {
                val code = restored[index].code
                if (code < 128 && reverseUriSafe[code] >= 0) reverseUriSafe[code] else 0
            }
        }
    }

    /**
     * Direct port of the reference `_decompress(length, resetValue,
     * getNextValue)`. Returns null for an invalid dictionary index and `""`
     * where the reference returns `""` (early end marker / out-of-bounds
     * symbol read).
     */
    private inline fun decompress(length: Int, resetValue: Int, getNextValue: (Int) -> Int): String? {
        val dictionary = ArrayList<String>(64)
        // Indices 0..2 are numeric placeholders in JS and are never read back
        // (the 0/1/2 symbol values are consumed by the switch); empty-string
        // placeholders keep the indices aligned.
        repeat(3) { dictionary.add("") }
        var enlargeIn = 4
        var dictSize = 4
        var numBits = 3
        val result = StringBuilder()

        var dataVal = getNextValue(0)
        var dataPosition = resetValue
        var dataIndex = 1

        var bits: Int
        var maxpower: Int
        var power: Int

        // First token: 2 bits selecting an 8-bit literal (0), a 16-bit
        // literal (1) or the end marker (2).
        bits = 0
        maxpower = 1 shl 2
        power = 1
        while (power != maxpower) {
            val resb = dataVal and dataPosition
            dataPosition = dataPosition shr 1
            if (dataPosition == 0) {
                dataPosition = resetValue
                dataVal = getNextValue(dataIndex++)
            }
            if (resb > 0) bits = bits or power
            power = power shl 1
        }
        val first: String
        when (bits) {
            0, 1 -> {
                val width = if (bits == 0) 8 else 16
                var literal = 0
                maxpower = 1 shl width
                power = 1
                while (power != maxpower) {
                    val resb = dataVal and dataPosition
                    dataPosition = dataPosition shr 1
                    if (dataPosition == 0) {
                        dataPosition = resetValue
                        dataVal = getNextValue(dataIndex++)
                    }
                    if (resb > 0) literal = literal or power
                    power = power shl 1
                }
                first = literal.toChar().toString()
            }
            2 -> return ""
            // Impossible in real output; the reference returns ""/throws
            // (masked to '' by the web wrapper) — see class doc.
            else -> return null
        }
        dictionary.add(first) // index 3
        var w = first
        result.append(first)

        while (true) {
            if (dataIndex > length) return ""

            bits = 0
            maxpower = 1 shl numBits
            power = 1
            while (power != maxpower) {
                val resb = dataVal and dataPosition
                dataPosition = dataPosition shr 1
                if (dataPosition == 0) {
                    dataPosition = resetValue
                    dataVal = getNextValue(dataIndex++)
                }
                if (resb > 0) bits = bits or power
                power = power shl 1
            }

            var c = bits
            when (c) {
                0, 1 -> {
                    val width = if (c == 0) 8 else 16
                    var literal = 0
                    maxpower = 1 shl width
                    power = 1
                    while (power != maxpower) {
                        val resb = dataVal and dataPosition
                        dataPosition = dataPosition shr 1
                        if (dataPosition == 0) {
                            dataPosition = resetValue
                            dataVal = getNextValue(dataIndex++)
                        }
                        if (resb > 0) literal = literal or power
                        power = power shl 1
                    }
                    dictionary.add(literal.toChar().toString())
                    dictSize++
                    c = dictSize - 1
                    enlargeIn--
                }
                2 -> return result.toString()
            }

            if (enlargeIn == 0) {
                enlargeIn = 1 shl numBits
                numBits++
            }

            val entry: String = when {
                c < dictSize -> dictionary[c]
                c == dictSize -> w + w[0]
                else -> return null
            }
            result.append(entry)

            // Add w + entry[0] to the dictionary.
            dictionary.add(w + entry[0])
            dictSize++
            enlargeIn--

            w = entry

            if (enlargeIn == 0) {
                enlargeIn = 1 shl numBits
                numBits++
            }
        }
    }
}
