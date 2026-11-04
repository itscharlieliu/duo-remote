import Foundation
import CoreGraphics

/// Events the RFB client reports back to its owner (on the main actor).
enum RFBEvent {
    case connected(name: String, width: Int, height: Int)
    case frame(CGImage)
    case cursor(CGImage?, hotspot: CGPoint)
    case resized(width: Int, height: Int)
    case stats(fps: Double, latencyMs: Double)
    case clipboard(String)
    case bell
    case failed(Error)
    case closed
}

/// An RFB 3.8 client for macOS Screen Sharing.
///
/// Supports Apple account sign-in (type 30) and VNC password (type 2);
/// ZRLE, CopyRect and Raw encodings; the Cursor and DesktopSize
/// pseudo-encodings. Runs its read loop on a detached task and calls
/// `onEvent` on the main actor.
final class RFBClient: @unchecked Sendable {
    struct Credentials: Sendable {
        var username: String
        var password: String
    }

    private let credentials: Credentials
    private let socket: RFBSocket
    private let onEvent: @MainActor (RFBEvent) -> Void
    private var task: Task<Void, Never>?

    private let stateLock = NSLock()
    private var _format = RFBPixelFormat.full
    private var pendingFormat: RFBPixelFormat?
    private var adaptive: Bool
    private(set) var framebuffer = Framebuffer(width: 1, height: 1)
    private let zrle = ZRLEDecoder()

    // Stats
    private var requestSentAt = Date()
    private var frameTimes: [Date] = []
    private var latencies: [Double] = []
    private var slowUpdates = 0

    convenience init(host: String, port: Int, credentials: Credentials, quality: Preferences.Quality,
                     onEvent: @escaping @MainActor (RFBEvent) -> Void) {
        self.init(socket: RFBSocket(host: host, port: port), credentials: credentials,
                  quality: quality, onEvent: onEvent)
    }

    /// `socket` may already be open; `run` opens it if not.
    init(socket: RFBSocket, credentials: Credentials, quality: Preferences.Quality,
         onEvent: @escaping @MainActor (RFBEvent) -> Void) {
        self.credentials = credentials
        self.onEvent = onEvent
        self.adaptive = quality == .adaptive
        self._format = quality == .low ? .compact : .full
        self.socket = socket
    }

    func start() {
        task = Task.detached(priority: .userInitiated) { [self] in
            do {
                try await run()
            } catch is CancellationError {
                await emit(.closed)
            } catch {
                await emit(.failed(error))
            }
            socket.close()
        }
    }

    func stop() {
        task?.cancel()
        socket.close()
    }

    private func emit(_ event: RFBEvent) async {
        await MainActor.run { onEvent(event) }
    }

    // MARK: Handshake

    private func run() async throws {
        try await socket.open()

        let version = String(decoding: try await socket.read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else { throw RFBError.protocolError("not an RFB server") }
        socket.write(Array("RFB 003.008\n".utf8))

        let count = Int(try await socket.u8())
        if count == 0 {
            let length = Int(try await socket.u32())
            let reason = String(decoding: try await socket.read(length), as: UTF8.self)
            throw RFBError.refused(reason)
        }
        let types = Array(try await socket.read(count))

        if types.contains(30) {
            socket.write([30])
            try await RFBAuth.appleDH(socket: socket, username: credentials.username, password: credentials.password)
        } else if types.contains(2) {
            socket.write([2])
            try await RFBAuth.vncPassword(socket: socket, password: credentials.password)
        } else if types.contains(1) {
            socket.write([1])
        } else {
            throw RFBError.unsupportedSecurity(types)
        }

        let result = try await socket.u32()
        if result != 0 {
            var reason = ""
            if let length = try? await socket.u32(), length < 4096,
               let bytes = try? await socket.read(Int(length)) {
                reason = String(decoding: bytes, as: UTF8.self)
            }
            throw RFBError.authFailed(reason)
        }

        socket.write([1]) // ClientInit: shared — don't kick the person at the Mac
        let width = Int(try await socket.u16())
        let height = Int(try await socket.u16())
        _ = try await socket.read(16) // server pixel format; we override it
        let nameLength = Int(try await socket.u32())
        let name = String(decoding: try await socket.read(min(nameLength, 1024)), as: UTF8.self)
        if nameLength > 1024 { try await socket.skip(nameLength - 1024) }

        framebuffer = Framebuffer(width: width, height: height)
        sendPixelFormat(format)
        sendEncodings()
        await emit(.connected(name: name, width: width, height: height))
        requestUpdate(incremental: false)

        try await messageLoop()
    }

    private var format: RFBPixelFormat {
        stateLock.withLock { _format }
    }

    private func sendPixelFormat(_ format: RFBPixelFormat) {
        socket.write([0, 0, 0, 0] + format.wire)
    }

    private func sendEncodings() {
        let encodings: [Int32] = [
            16,    // ZRLE
            1,     // CopyRect
            0,     // Raw
            -239,  // Cursor pseudo-encoding: draw the pointer locally
            -223,  // DesktopSize pseudo-encoding
        ]
        var message: [UInt8] = [2, 0]
        message.appendU16(UInt16(encodings.count))
        for e in encodings { message.appendU32(UInt32(bitPattern: e)) }
        socket.write(message)
    }

    private func requestUpdate(incremental: Bool) {
        var message: [UInt8] = [3, incremental ? 1 : 0]
        message.appendU16(0); message.appendU16(0)
        message.appendU16(UInt16(framebuffer.width)); message.appendU16(UInt16(framebuffer.height))
        requestSentAt = Date()
        socket.write(message)
    }

    // MARK: Server messages

    private func messageLoop() async throws {
        while !Task.isCancelled {
            let type = try await socket.u8()
            switch type {
            case 0:
                try await framebufferUpdate()
            case 1: // SetColourMapEntries — unused in true colour
                _ = try await socket.read(1)
                _ = try await socket.u16()
                let n = Int(try await socket.u16())
                try await socket.skip(n * 6)
            case 2:
                await emit(.bell)
            case 3:
                _ = try await socket.read(3)
                let length = Int(try await socket.u32())
                let bytes = try await socket.read(min(length, 1 << 20))
                if length > 1 << 20 { try await socket.skip(length - (1 << 20)) }
                // RFB cut text is Latin-1.
                let text = String(bytes: bytes, encoding: .isoLatin1) ?? ""
                await emit(.clipboard(text))
            default:
                throw RFBError.protocolError("unexpected message \(type)")
            }
        }
        throw CancellationError()
    }

    private func framebufferUpdate() async throws {
        _ = try await socket.read(1)
        let rects = Int(try await socket.u16())
        var changed = false
        let format = self.format

        for _ in 0..<rects {
            let x = Int(try await socket.u16())
            let y = Int(try await socket.u16())
            let w = Int(try await socket.u16())
            let h = Int(try await socket.u16())
            let encoding = try await socket.s32()

            switch encoding {
            case 0: // Raw
                let bpp = format.bytesPerPixel
                let row = w * bpp
                for r in 0..<h {
                    let bytes = try await socket.read(row)
                    framebuffer.withLock {
                        guard framebuffer.clip(x, y + r, w, 1) else { return }
                        let dst = framebuffer.pixels + (y + r) * framebuffer.width + x
                        bytes.withUnsafeBufferPointer { src in
                            for c in 0..<w { dst[c] = format.pixel(src.baseAddress! + c * bpp, cpixel: false) }
                        }
                    }
                }
                changed = true
            case 1: // CopyRect
                let sx = Int(try await socket.u16())
                let sy = Int(try await socket.u16())
                framebuffer.withLock { framebuffer.copyRect(srcX: sx, srcY: sy, x: x, y: y, w: w, h: h) }
                changed = true
            case 16: // ZRLE
                let length = Int(try await socket.u32())
                let compressed = try await socket.read(length)
                let data = try zrle.inflate(compressed)
                try zrle.decode(data, x: x, y: y, w: w, h: h, format: format, into: framebuffer)
                changed = true
            case -239: // Cursor
                let bpp = format.bytesPerPixel
                let pixels = Array(try await socket.read(w * h * bpp))
                let mask = Array(try await socket.read(((w + 7) / 8) * h))
                let image = Self.cursorImage(w: w, h: h, pixels: pixels, mask: mask, format: format)
                await emit(.cursor(image, hotspot: CGPoint(x: x, y: y)))
            case -223: // DesktopSize
                framebuffer.resize(width: w, height: h)
                zrle.reset()
                await emit(.resized(width: w, height: h))
                changed = true
            default:
                throw RFBError.protocolError("unsupported encoding \(encoding)")
            }
        }

        if changed, let image = framebuffer.makeImage() {
            await emit(.frame(image))
        }
        await recordStats()

        // Apply a format change between updates, never mid-update.
        if let next = stateLock.withLock({ () -> RFBPixelFormat? in
            defer { pendingFormat = nil }
            if let p = pendingFormat { _format = p }
            return pendingFormat
        }) {
            sendPixelFormat(next)
            requestUpdate(incremental: false)
        } else {
            requestUpdate(incremental: true)
        }
    }

    private func recordStats() async {
        let now = Date()
        let latency = now.timeIntervalSince(requestSentAt) * 1000
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        latencies.append(latency)
        if latencies.count > 20 { latencies.removeFirst() }

        // Adaptive quality: incremental requests on an idle desktop also come
        // back slowly (the server waits for change), so only count updates
        // that arrived while the screen was busy.
        if adaptive, frameTimes.count >= 4, latency > 220 {
            slowUpdates += 1
            if slowUpdates >= 6, format == .full {
                stateLock.withLock { pendingFormat = .compact }
                adaptive = false
            }
        } else if latency < 120 {
            slowUpdates = max(0, slowUpdates - 1)
        }

        let sorted = latencies.sorted()
        let median = sorted[sorted.count / 2]
        await emit(.stats(fps: Double(frameTimes.count), latencyMs: median))
    }

    private static func cursorImage(w: Int, h: Int, pixels: [UInt8], mask: [UInt8], format: RFBPixelFormat) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt32](repeating: 0, count: w * h)
        let bpp = format.bytesPerPixel
        let maskStride = (w + 7) / 8
        pixels.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w {
                    let visible = mask[y * maskStride + x / 8] & (0x80 >> (x % 8)) != 0
                    guard visible else { continue }
                    // Premultiplied BGRA, opaque.
                    rgba[y * w + x] = format.pixel(src.baseAddress! + (y * w + x) * bpp, cpixel: false)
                }
            }
        }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return rgba.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
        }
    }

    // MARK: Client → server

    func pointer(x: Int, y: Int, buttons: UInt8) {
        let cx = UInt16(clamping: max(0, min(x, framebuffer.width - 1)))
        let cy = UInt16(clamping: max(0, min(y, framebuffer.height - 1)))
        var message: [UInt8] = [5, buttons]
        message.appendU16(cx); message.appendU16(cy)
        socket.write(message)
    }

    func key(_ keysym: UInt32, down: Bool) {
        var message: [UInt8] = [4, down ? 1 : 0, 0, 0]
        message.appendU32(keysym)
        socket.write(message)
    }

    func clipboard(_ text: String) {
        let bytes = Array(text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data())
        var message: [UInt8] = [6, 0, 0, 0]
        message.appendU32(UInt32(bytes.count))
        socket.write(message + bytes)
    }
}
