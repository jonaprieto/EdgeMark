import Foundation

/// Bech32 (BIP 173) without the 90-character limit, as the age format uses it for
/// recipients (`age1...`) and identities (`AGE-SECRET-KEY-1...`).
nonisolated enum Bech32 {
    private static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1FF_FFFF) << 5 ^ UInt32(value)
            for i in 0 ..< 5 where (top >> UInt32(i)) & 1 == 1 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    private static func expand(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    /// Regroups `input` from `from`-bit to `to`-bit values. With `pad` false, leftover
    /// bits must be zero and fewer than `from`, else nil.
    private static func convert(_ input: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var out: [UInt8] = []
        let maxValue = (1 << to) - 1
        for value in input {
            guard Int(value) >> from == 0 else { return nil }
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxValue))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxValue)) }
        } else if bits >= from || (acc << (to - bits)) & maxValue != 0 {
            return nil
        }
        return out
    }

    /// Lowercase Bech32 string for `data` under the human-readable part `hrp` (lowercase).
    static func encode(hrp: String, data: Data) -> String {
        let values = convert(Array(data), from: 8, to: 5, pad: true) ?? []
        let mod = polymod(expand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksum = (0 ..< 6).map { UInt8((mod >> UInt32(5 * (5 - $0))) & 31) }
        return hrp + "1" + String(decoding: (values + checksum).map { alphabet[Int($0)] }, as: UTF8.self)
    }

    /// The human-readable part (lowercased) and the data of a Bech32 string. Nil for mixed
    /// case, a bad checksum, a character outside the alphabet or non-zero padding.
    static func decode(_ string: String) -> (hrp: String, data: Data)? {
        let lower = string.lowercased()
        guard string == lower || string == string.uppercased(),
              let separator = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[..<separator])
        let payload = Array(lower[lower.index(after: separator)...].utf8)
        guard !hrp.isEmpty, payload.count >= 6, hrp.utf8.allSatisfy({ (33 ... 126).contains($0) }) else { return nil }
        var values: [UInt8] = []
        for character in payload {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            values.append(UInt8(index))
        }
        guard polymod(expand(hrp) + values) == 1,
              let bytes = convert(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (hrp, Data(bytes))
    }
}
