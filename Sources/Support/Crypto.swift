import Foundation
import CryptoKit
import Compression

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256Hex(fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// CRC32 chuẩn ZIP (poly 0xEDB88320).
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    public static func checksum(fileURL: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var c: UInt32 = 0xFFFFFFFF
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            for byte in chunk { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            return true
        }) {}
        return c ^ 0xFFFFFFFF
    }
}

/// Nén/ giải nén raw DEFLATE khớp phương thức 8 của ZIP bằng Compression framework.
public enum Deflate {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let dstCapacity = data.count + 1024
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_encode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        dst.removeSubrange(written..<dst.count)
        return dst
    }

    /// Giải nén với giới hạn bytes tối đa để chống decompression bomb.
    /// Dùng streaming API (compression_stream) — DEFLATE là stream theo bit,
    /// không thể decode lại từ offset byte tùy ý bằng API one-shot.
    public static func decompress(_ data: Data, maxUncompressed: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        let srcBufferSize = data.count
        let srcBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: srcBufferSize)
        defer { srcBuffer.deallocate() }
        data.copyBytes(to: srcBuffer, count: srcBufferSize)

        let dstCapacity = 1 << 20
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        let initStatus = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }

        var output = Data()
        var srcOffset = 0
        var done = false
        while !done {
            // Cung cấp nguồn theo chunk; hết nguồn → FINALIZE để flush phần cuối
            if srcOffset < srcBufferSize {
                let n = min(1 << 18, srcBufferSize - srcOffset)
                stream.pointee.src_ptr = UnsafePointer(srcBuffer + srcOffset)
                stream.pointee.src_size = n
                srcOffset += n
            } else {
                stream.pointee.src_ptr = UnsafePointer(srcBuffer)
                stream.pointee.src_size = 0
            }
            stream.pointee.dst_ptr = dstBuffer
            stream.pointee.dst_size = dstCapacity
            let flags: Int32 = srcOffset >= srcBufferSize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let produced = stream.pointee.dst_ptr - dstBuffer
            if produced > 0 {
                output.append(dstBuffer, count: produced)
            }
            // Stream có thể chưa tiêu thụ hết chunk đã cung cấp — src_size còn lại là phần chưa đọc,
            // lùi srcOffset để lần lặp sau cung cấp lại từ đúng chỗ.
            srcOffset -= Int(stream.pointee.src_size)
            // Chống decompression bomb — vượt giới hạn thì hủy, không trả dữ liệu dở
            if output.count > maxUncompressed { return nil }
            switch status {
            case COMPRESSION_STATUS_OK:
                // Đã FINALIZE mà không tiến triển → dữ liệu đầu vào hỏng/thiếu
                if produced == 0 && srcOffset >= srcBufferSize && flags != 0 {
                    return nil
                }
            case COMPRESSION_STATUS_END:
                done = true
            default:
                return nil
            }
        }
        return output
    }
}
