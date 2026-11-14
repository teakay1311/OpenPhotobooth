import Foundation

/// ZIP reader/writer tối thiểu (method 0 store / 8 deflate bằng Compression framework).
/// Dùng cho Frame Pack (§13). Không phụ thuộc thư viện ngoài.
public enum ZipArchive {
    public struct Entry: Equatable {
        public var name: String
        public var data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }

    public struct CentralEntry: Equatable {
        public var name: String
        public var method: UInt16
        public var crc32: UInt32
        public var compressedSize: UInt32
        public var uncompressedSize: UInt32
        public var localHeaderOffset: UInt32
        public var externalAttributes: UInt32
        public var isSymlink: Bool { (externalAttributes >> 16) & 0o170000 == 0o120000 }
    }

    // MARK: - Writer

    public static func archive(entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        var count: UInt16 = 0
        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let compressed = Deflate.compress(entry.data)
            let useDeflate = compressed.map { $0.count < entry.data.count } ?? false
            let method: UInt16 = useDeflate ? 8 : 0
            let stored = useDeflate ? compressed! : entry.data
            let offset = UInt32(out.count)
            // Local file header
            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))        // version needed
            out.appendLE(UInt16(0))         // flags
            out.appendLE(method)
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0)) // dos time/date
            out.appendLE(crc)
            out.appendLE(UInt32(stored.count))
            out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))
            out.append(nameBytes)
            out.append(stored)
            // Central directory record
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0)); central.appendLE(method)
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(crc)
            central.appendLE(UInt32(stored.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))   // extra
            central.appendLE(UInt16(0))   // comment
            central.appendLE(UInt16(0))   // disk number
            central.appendLE(UInt16(0))   // internal attrs
            central.appendLE(UInt32(0))   // external attrs
            central.appendLE(offset)
            central.append(nameBytes)
            count += 1
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // EOCD
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(count); out.appendLE(count)
        out.appendLE(UInt32(central.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }

    // MARK: - Reader (verify trước khi extract §13.2)

    public static func read(data: Data) throws -> [CentralEntry] {
        guard data.count > 22 else { throw AppError.unsafeFramePack("File quá nhỏ") }
        // Tìm EOCD từ cuối
        var eocdOffset = -1
        let minOffset = max(0, data.count - 66_000)
        var i = data.count - 22
        while i >= minOffset {
            if data.readU32(at: i) == 0x06054b50 { eocdOffset = i; break }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw AppError.unsafeFramePack("Không tìm thấy EOCD") }
        let entryCount = Int(data.readU16(at: eocdOffset + 10))
        guard entryCount <= ResourceLimits.maxPackEntries else {
            throw AppError.unsafeFramePack("Số entry vượt giới hạn (\(entryCount))")
        }
        var cdOffset = Int(data.readU32(at: eocdOffset + 16))
        var entries: [CentralEntry] = []
        for _ in 0..<entryCount {
            guard cdOffset + 46 <= data.count, data.readU32(at: cdOffset) == 0x02014b50 else {
                throw AppError.unsafeFramePack("Central directory hỏng")
            }
            let nameLen = Int(data.readU16(at: cdOffset + 28))
            let extraLen = Int(data.readU16(at: cdOffset + 30))
            let commentLen = Int(data.readU16(at: cdOffset + 32))
            guard cdOffset + 46 + nameLen <= data.count else { throw AppError.unsafeFramePack("Tên entry hỏng") }
            let nameData = data.subdata(in: (cdOffset + 46)..<(cdOffset + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            let entry = CentralEntry(name: name,
                                     method: data.readU16(at: cdOffset + 10),
                                     crc32: data.readU32(at: cdOffset + 16),
                                     compressedSize: data.readU32(at: cdOffset + 20),
                                     uncompressedSize: data.readU32(at: cdOffset + 24),
                                     localHeaderOffset: data.readU32(at: cdOffset + 42),
                                     externalAttributes: data.readU32(at: cdOffset + 38))
            entries.append(entry)
            cdOffset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Extract một entry vào bộ nhớ với giới hạn (chống decompression bomb, PACK-03).
    public static func extract(data: Data, entry: CentralEntry, maxUncompressedBytes: Int) throws -> Data {
        guard !entry.isSymlink else { throw AppError.unsafeFramePack("Entry symlink bị chặn") }
        guard Int(entry.uncompressedSize) <= maxUncompressedBytes else {
            throw AppError.unsafeFramePack("Entry vượt giới hạn kích thước")
        }
        guard Int(entry.uncompressedSize) <= ResourceLimits.maxPackUncompressedBytes else {
            throw AppError.unsafeFramePack("Entry vượt 1GB")
        }
        let off = Int(entry.localHeaderOffset)
        guard off + 30 <= data.count, data.readU32(at: off) == 0x04034b50 else {
            throw AppError.unsafeFramePack("Local header hỏng")
        }
        let nameLen = Int(data.readU16(at: off + 26))
        let extraLen = Int(data.readU16(at: off + 28))
        let dataStart = off + 30 + nameLen + extraLen
        let compEnd = dataStart + Int(entry.compressedSize)
        guard compEnd <= data.count else { throw AppError.unsafeFramePack("Dữ liệu entry hỏng") }
        let compressed = data.subdata(in: dataStart..<compEnd)
        let result: Data
        switch entry.method {
        case 0:
            result = compressed
        case 8:
            guard let d = Deflate.decompress(compressed, maxUncompressed: maxUncompressedBytes) else {
                throw AppError.unsafeFramePack("Giải nén thất bại hoặc vượt giới hạn")
            }
            result = d
        default:
            throw AppError.unsafeFramePack("Phương thức nén không hỗ trợ: \(entry.method)")
        }
        guard result.count == Int(entry.uncompressedSize) else {
            throw AppError.unsafeFramePack("Kích thước sau giải nén lệch manifest")
        }
        guard CRC32.checksum(result) == entry.crc32 else {
            throw AppError.unsafeFramePack("CRC32 không khớp")
        }
        return result
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    func readU16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }
    func readU32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}
