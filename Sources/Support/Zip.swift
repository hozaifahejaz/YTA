import Foundation

/// A minimal ZIP writer (stored, no compression), enough for .docx files.
public enum ZipWriter {
    public static func archive(_ entries: [(path: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (path, data) in entries {
            let name = Data(path.utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            out += le32(0x04034b50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
            out += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(UInt16(name.count)) + le16(0)
            out += name + data
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21)
            central += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(UInt16(name.count))
            central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let start = UInt32(out.count)
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        out += le32(UInt32(central.count)) + le32(start) + le16(0)
        return out
    }

    /// Reads the entries of a stored ZIP written by `archive`. Used by tests.
    public static func entries(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var result: [String: Data] = [:]
        var index = 0
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        while index + 30 <= bytes.count, u32(index) == 0x04034b50 {
            let size = u32(index + 18), nameLength = u16(index + 26), extra = u16(index + 28)
            let name = String(decoding: bytes[(index + 30)..<(index + 30 + nameLength)], as: UTF8.self)
            let start = index + 30 + nameLength + extra
            result[name] = Data(bytes[start..<(start + size)])
            index = start + size
        }
        return result
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xff), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) }) }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}
