import Foundation
import CZlib

// Read entries in memory. Never extract untrusted paths onto the filesystem.
struct ZIPArchive {
    struct Entry {
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressed: Int
        let uncompressed: Int
        let offset: Int
    }
    let data: Data
    let entries: [String: Entry]

    init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1024 * 1024 else { throw AudiobookError.invalidEPUB("This EPUB exceeds the 256 MB archive limit.") }
        let data = try Data(contentsOf: url)
        self.data = data
        guard data.count >= 22 else { throw AudiobookError.invalidEPUB("This file is not a valid EPUB ZIP archive.") }
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
            data.u32($0) == 0x06054b50 && $0 + 22 + Int(data.u16($0 + 20)) == data.count
        }) else { throw AudiobookError.invalidEPUB("The EPUB ZIP directory is missing or damaged.") }
        guard data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10),
              data.u16(end + 10) != UInt16.max, data.u32(end + 16) != UInt32.max else {
            throw AudiobookError.invalidEPUB("ZIP64 and multipart EPUB archives are not supported.")
        }
        let count = Int(data.u16(end + 10))
        let directoryEnd = Int(data.u32(end + 16)) + Int(data.u32(end + 12))
        var cursor = Int(data.u32(end + 16))
        guard directoryEnd <= end, cursor <= directoryEnd else { throw AudiobookError.invalidEPUB("Invalid ZIP directory bounds.") }
        var parsed: [String: Entry] = [:]
        for _ in 0..<count {
            guard cursor + 46 <= directoryEnd, data.u32(cursor) == 0x02014b50 else {
                throw AudiobookError.invalidEPUB("The EPUB ZIP directory contains a damaged entry.")
            }
            let nameLength = Int(data.u16(cursor + 28))
            let next = cursor + 46 + nameLength + Int(data.u16(cursor + 30)) + Int(data.u16(cursor + 32))
            guard next <= directoryEnd, data.u16(cursor + 34) == 0 else { throw AudiobookError.invalidEPUB("Invalid ZIP entry bounds.") }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .utf8), !name.contains("\\"), !name.hasPrefix("/"),
                  !name.components(separatedBy: "/").contains(".."), parsed[name] == nil else {
                throw AudiobookError.invalidEPUB("The EPUB contains an invalid or duplicate resource path.")
            }
            let entry = Entry(flags: data.u16(cursor + 8), method: data.u16(cursor + 10),
                              crc: data.u32(cursor + 16), compressed: Int(data.u32(cursor + 20)),
                              uncompressed: Int(data.u32(cursor + 24)), offset: Int(data.u32(cursor + 42)))
            guard entry.compressed != Int(UInt32.max), entry.uncompressed != Int(UInt32.max), entry.offset != Int(UInt32.max) else {
                throw AudiobookError.invalidEPUB("ZIP64 EPUB resources are not supported.")
            }
            parsed[name] = entry
            cursor = next
        }
        guard cursor == directoryEnd else { throw AudiobookError.invalidEPUB("Inconsistent EPUB ZIP directory.") }
        entries = parsed
    }

    func read(_ path: String) throws -> Data {
        guard let entry = entries[path] else { throw AudiobookError.invalidEPUB("Missing EPUB resource: \(path)") }
        guard entry.flags & 1 == 0 else { throw AudiobookError.invalidEPUB("This EPUB contains encrypted text and cannot be narrated.") }
        guard entry.uncompressed <= 32 * 1024 * 1024 else { throw AudiobookError.invalidEPUB("An EPUB text resource exceeds the 32 MB limit.") }
        let offset = entry.offset
        guard offset + 30 <= data.count, data.u32(offset) == 0x04034b50 else { throw AudiobookError.invalidEPUB("Damaged ZIP resource: \(path)") }
        let start = offset + 30 + Int(data.u16(offset + 26)) + Int(data.u16(offset + 28))
        guard start + entry.compressed <= data.count else { throw AudiobookError.invalidEPUB("Truncated ZIP resource: \(path)") }
        let compressed = data.subdata(in: start..<start + entry.compressed)
        let result: Data
        switch entry.method {
        case 0: result = compressed
        case 8:
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw AudiobookError.invalidEPUB("Unable to initialize EPUB decompression.")
            }
            defer { inflateEnd(&stream) }
            var expanded = Data(count: max(1, entry.uncompressed))
            let status = compressed.withUnsafeBytes { input in
                expanded.withUnsafeMutableBytes { output in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.uncompressed, stream.total_in == entry.compressed else {
                throw AudiobookError.invalidEPUB("Unable to decompress EPUB resource: \(path)")
            }
            result = expanded.prefix(entry.uncompressed)
        default: throw AudiobookError.invalidEPUB("Unsupported EPUB compression method: \(entry.method)")
        }
        guard result.count == entry.uncompressed else { throw AudiobookError.invalidEPUB("Incorrect EPUB resource size: \(path)") }
        let checksum = result.withUnsafeBytes { bytes in crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
        guard UInt32(checksum) == entry.crc else { throw AudiobookError.invalidEPUB("EPUB checksum failed: \(path)") }
        return result
    }
}

private extension Data {
    func u16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
    func u32(_ index: Int) -> UInt32 { UInt32(u16(index)) | UInt32(u16(index + 2)) << 16 }
}
