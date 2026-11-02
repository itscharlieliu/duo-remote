import Foundation
import CoreGraphics
import zlib

/// The remote screen's pixels, as BGRX words in memory (little-endian
/// 0x00RRGGBB), which CoreGraphics reads directly with
/// `byteOrder32Little | noneSkipFirst`.
final class Framebuffer: @unchecked Sendable {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: UnsafeMutablePointer<UInt32>
    private let lock = NSLock()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: max(1, width * height))
        pixels.initialize(repeating: 0xFF1A222C, count: max(1, width * height))
    }

    deinit { pixels.deallocate() }

    func resize(width: Int, height: Int) {
        lock.withLock {
            pixels.deallocate()
            self.width = width
            self.height = height
            pixels = .allocate(capacity: max(1, width * height))
            pixels.initialize(repeating: 0, count: max(1, width * height))
        }
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    func fill(x: Int, y: Int, w: Int, h: Int, color: UInt32) {
        guard clip(x, y, w, h) else { return }
        for row in y..<(y + h) {
            (pixels + row * width + x).update(repeating: color, count: w)
        }
    }

    func copyRect(srcX: Int, srcY: Int, x: Int, y: Int, w: Int, h: Int) {
        guard clip(x, y, w, h), clip(srcX, srcY, w, h) else { return }
        let rows = srcY < y ? Array((0..<h).reversed()) : Array(0..<h)
        for r in rows {
            let src = pixels + (srcY + r) * width + srcX
            let dst = pixels + (y + r) * width + x
            memmove(dst, src, w * 4)
        }
    }

    func clip(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height
    }

    /// A copy of the current frame. Copy-on-write inside CoreGraphics keeps
    /// this cheap until the decoder writes again.
    func makeImage() -> CGImage? {
        lock.withLock {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            guard let context = CGContext(
                data: pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return nil }
            return context.makeImage()
        }
    }
}

/// Pixel format negotiated with the server. Home Row only asks for true
/// colour, in 32bpp (full quality) or 16bpp RGB565 (half the bandwidth).
struct RFBPixelFormat: Equatable {
    var bitsPerPixel: Int

    static let full = RFBPixelFormat(bitsPerPixel: 32)
    static let compact = RFBPixelFormat(bitsPerPixel: 16)

    var bytesPerPixel: Int { bitsPerPixel / 8 }
    /// ZRLE's "compressed pixel": 3 bytes for 32bpp depth-24.
    var bytesPerCPixel: Int { bitsPerPixel == 32 ? 3 : 2 }

    var wire: [UInt8] {
        var b: [UInt8] = []
        if bitsPerPixel == 32 {
            b += [32, 24, 0, 1]            // bpp, depth, big-endian=false, true-colour
            b.appendU16(255); b.appendU16(255); b.appendU16(255)
            b += [16, 8, 0]
        } else {
            b += [16, 16, 0, 1]
            b.appendU16(31); b.appendU16(63); b.appendU16(31)
            b += [11, 5, 0]
        }
        b += [0, 0, 0]
        return b
    }

    @inline(__always)
    func pixel(_ p: UnsafePointer<UInt8>, cpixel: Bool) -> UInt32 {
        if bitsPerPixel == 32 {
            return 0xFF00_0000 | UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16
        }
        let v = UInt32(p[0]) | UInt32(p[1]) << 8
        let r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F
        return 0xFF00_0000 | ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2)
    }
}

/// ZRLE (encoding 16). One zlib stream spans the whole connection; each
/// rectangle's data is a sync-flushed chunk of it, inflated then decoded as
/// 64×64 tiles.
final class ZRLEDecoder {
    private var stream = z_stream()
    private var ready = false
    private var output = [UInt8](repeating: 0, count: 1 << 20)

    deinit { if ready { inflateEnd(&stream) } }

    func reset() {
        if ready { inflateEnd(&stream) }
        ready = false
    }

    func inflate(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        if !ready {
            stream = z_stream()
            guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw RFBError.protocolError("zlib init failed")
            }
            ready = true
        }
        var result = [UInt8]()
        result.reserveCapacity(input.count * 4)
        var source = Array(input)
        try source.withUnsafeMutableBufferPointer { src in
            stream.next_in = src.baseAddress
            stream.avail_in = uInt(src.count)
            repeat {
                let produced: Int = try output.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let status = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END else {
                        throw RFBError.protocolError("zlib error \(status)")
                    }
                    return out.count - Int(stream.avail_out)
                }
                result.append(contentsOf: output[0..<produced])
                if produced == 0 && stream.avail_in > 0 { break }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        return result
    }

    func decode(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int,
                format: RFBPixelFormat, into fb: Framebuffer) throws {
        let cp = format.bytesPerCPixel
        try data.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            let end = buf.count

            func need(_ n: Int) throws {
                if i + n > end { throw RFBError.protocolError("ZRLE data truncated") }
            }
            func cpixel() throws -> UInt32 {
                try need(cp)
                defer { i += cp }
                return format.pixel(base + i, cpixel: true)
            }
            func runLength() throws -> Int {
                var length = 1
                while true {
                    try need(1)
                    let b = Int(base[i]); i += 1
                    length += b
                    if b != 255 { return length }
                }
            }

            try fb.withLock {
                let stride = fb.width
                let pixels = fb.pixels
                guard fb.clip(x, y, w, h) else { throw RFBError.protocolError("ZRLE rect outside screen") }
                var palette = [UInt32](repeating: 0, count: 128)

                var ty = y
                while ty < y + h {
                    let th = min(64, y + h - ty)
                    var tx = x
                    while tx < x + w {
                        let tw = min(64, x + w - tx)
                        try need(1)
                        let sub = Int(base[i]); i += 1
                        let origin = pixels + ty * stride + tx

                        switch sub {
                        case 0: // raw
                            for r in 0..<th {
                                let row = origin + r * stride
                                for c in 0..<tw { row[c] = try cpixel() }
                            }
                        case 1: // solid
                            let color = try cpixel()
                            for r in 0..<th { (origin + r * stride).update(repeating: color, count: tw) }
                        case 2...16: // packed palette
                            for p in 0..<sub { palette[p] = try cpixel() }
                            let bits = sub == 2 ? 1 : (sub <= 4 ? 2 : 4)
                            let mask = (1 << bits) - 1
                            for r in 0..<th {
                                let row = origin + r * stride
                                var shift = 8
                                var byte = 0
                                for c in 0..<tw {
                                    if shift == 8 || shift - bits < 0 {
                                        try need(1); byte = Int(base[i]); i += 1; shift = 8
                                    }
                                    shift -= bits
                                    row[c] = palette[(byte >> shift) & mask]
                                }
                            }
                        case 128: // plain RLE
                            var n = 0
                            let total = tw * th
                            while n < total {
                                let color = try cpixel()
                                let run = try runLength()
                                for k in n..<min(total, n + run) {
                                    origin[(k / tw) * stride + k % tw] = color
                                }
                                n += run
                            }
                        case 130...255: // palette RLE
                            let count = sub - 128
                            for p in 0..<count { palette[p] = try cpixel() }
                            var n = 0
                            let total = tw * th
                            while n < total {
                                try need(1)
                                let index = Int(base[i]); i += 1
                                let run = index & 0x80 != 0 ? try runLength() : 1
                                let color = palette[index & 0x7F]
                                for k in n..<min(total, n + run) {
                                    origin[(k / tw) * stride + k % tw] = color
                                }
                                n += run
                            }
                        default:
                            throw RFBError.protocolError("ZRLE subencoding \(sub)")
                        }
                        tx += 64
                    }
                    ty += 64
                }
            }
        }
    }
}
