import Foundation

/// Native port of LZ-string 1.4.4 `decompressFromEncodedURIComponent`
/// (SPEC §11) — decompress only; the SDK never compresses.
///
/// Ported line-for-line from the reference JS (`libs/lz-string.js`,
/// Pieroxy, WTFPL), including its quirks:
///
/// - the URI-safe alphabet `A-Za-z0-9+-$`;
/// - the `" "` → `"+"` restoration (naive URL decoding turns the `+` output
///   character into a space; the reference restores it before decoding);
/// - a character outside the alphabet contributes 0-bits (JS reads
///   `undefined` from the reverse dictionary and `NaN & x === 0`) — garbage
///   input degrades to garbage/empty output, never a throw;
/// - reading past the end of input yields 0-bits (JS `charAt` → `""` →
///   `undefined`), while the symbol loop's own bounds check returns `""`;
/// - an invalid dictionary index returns nil (reference `return null`).
///
/// The algorithm operates on UTF-16 code units (JS string semantics);
/// the result is decoded as UTF-16 at the end.
///
/// Deviations (documented, garbage-input-only):
/// - JS returns `""` for a *null* input and `null` for `""`; the Swift
///   signature folds both to nil (nil-in → nil-out is the idiomatic port).
/// - A first 2-bit token of 3 is impossible in real compressed output (the
///   compressor emits 0/1/2 first); on such input the reference library
///   returns `""` or throws a `TypeError` (reading a property of the
///   `undefined` first entry), and the web tracker's wrapper masks the
///   throw to `''` — this port returns nil instead: safer and unambiguous
///   (pinned by the shared `garbage_first_token_3` vector).
/// - Garbage input can decode to lone UTF-16 surrogates, which JS strings
///   tolerate; Swift's UTF-16 decoding replaces them with U+FFFD. Valid
///   compressed data never hits this (surrogate pairs stay adjacent).
///
/// Behavior is pinned against the real JS library by
/// `shared/lzstring-vectors/vectors.json` (vectors generated with lz-string
/// 1.4.4 under node; garbage-case expectations are the library's actual
/// outputs, including its `""` results). Never throws.
enum LZString {

    private static let keyStrUriSafe =
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$".utf16)

    /// Char code → alphabet value; -1 for characters outside the alphabet.
    private static let reverseUriSafe: [Int] = {
        var table = [Int](repeating: -1, count: 128)
        for (value, unit) in keyStrUriSafe.enumerated() {
            table[Int(unit)] = value
        }
        return table
    }()

    static func decompressFromEncodedURIComponent(_ input: String?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        let restored = Array(input.replacingOccurrences(of: " ", with: "+").utf16)
        return decompress(length: restored.count, resetValue: 32) { index in
            guard index < restored.count else { return 0 }
            let code = Int(restored[index])
            return code < 128 && reverseUriSafe[code] >= 0 ? reverseUriSafe[code] : 0
        }
    }

    /// Direct port of the reference `_decompress(length, resetValue,
    /// getNextValue)`. Returns nil for an invalid dictionary index and `""`
    /// where the reference returns `""` (early end marker / out-of-bounds
    /// symbol read).
    private static func decompress(
        length: Int,
        resetValue: Int,
        getNextValue: (Int) -> Int
    ) -> String? {
        // Indices 0..2 are numeric placeholders in JS and are never read
        // back (the 0/1/2 symbol values are consumed by the switch); empty
        // placeholders keep the indices aligned. `dictionary.count` stays
        // equal to `dictSize` throughout.
        var dictionary: [[UInt16]] = [[], [], []]
        var enlargeIn = 4
        var dictSize = 4
        var numBits = 3
        var result: [UInt16] = []

        var dataVal = getNextValue(0)
        var dataPosition = resetValue
        var dataIndex = 1

        func readBits(_ count: Int) -> Int {
            var bits = 0
            var power = 1
            let maxpower = 1 << count
            while power != maxpower {
                let resb = dataVal & dataPosition
                dataPosition >>= 1
                if dataPosition == 0 {
                    dataPosition = resetValue
                    dataVal = getNextValue(dataIndex)
                    dataIndex += 1
                }
                if resb > 0 { bits |= power }
                power <<= 1
            }
            return bits
        }

        // First token: 2 bits selecting an 8-bit literal (0), a 16-bit
        // literal (1) or the end marker (2).
        let first: [UInt16]
        switch readBits(2) {
        case 0:
            first = [UInt16(truncatingIfNeeded: readBits(8))]
        case 1:
            first = [UInt16(truncatingIfNeeded: readBits(16))]
        case 2:
            return ""
        default:
            // Impossible in real output; the reference returns ""/throws
            // (masked to '' by the web wrapper) — see class doc.
            return nil
        }
        dictionary.append(first) // index 3
        var w = first
        result += first

        while true {
            if dataIndex > length { return "" }

            var c = readBits(numBits)
            switch c {
            case 0, 1:
                let literal = UInt16(truncatingIfNeeded: readBits(c == 0 ? 8 : 16))
                dictionary.append([literal])
                dictSize += 1
                c = dictSize - 1
                enlargeIn -= 1
            case 2:
                return String(decoding: result, as: UTF16.self)
            default:
                break
            }

            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }

            let entry: [UInt16]
            if c < dictSize {
                entry = dictionary[c]
            } else if c == dictSize {
                entry = w + [w[0]]
            } else {
                return nil
            }
            result += entry

            // Add w + entry[0] to the dictionary.
            dictionary.append(w + [entry[0]])
            dictSize += 1
            enlargeIn -= 1

            w = entry

            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }
    }
}
