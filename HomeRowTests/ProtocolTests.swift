import XCTest
import zlib
@testable import HomeRow

final class ProtocolTests: XCTestCase {

    // MARK: Host keys

    func testFingerprintMatchesSSHKeygen() {
        // `ssh-keygen -lf` on this key prints SHA256:EzfxxAs79ePVCXI+mlQeAC9Ot044tQm0HVS+HdbnFBs
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILRMbVi2lxMcLzIGTzyemea9c/1i0/LDf1YzYzbxbr7B test"
        XCTAssertEqual(HostKeyTrust.fingerprint(ofOpenSSHKey: line),
                       "SHA256:EzfxxAs79ePVCXI+mlQeAC9Ot044tQm0HVS+HdbnFBs")
        XCTAssertEqual(HostKeyTrust.algorithmLabel(ofOpenSSHKey: line), "ED25519")
    }

    func testSameKeyIgnoresComment() {
        XCTAssertTrue(HostKeyTrust.sameKey("ssh-ed25519 AAAA one", "ssh-ed25519 AAAA"))
        XCTAssertFalse(HostKeyTrust.sameKey("ssh-ed25519 AAAA", "ssh-ed25519 AAAB"))
    }

    // MARK: LAN guard

    func testLocalAddresses() {
        for ip in ["192.168.1.20", "10.0.0.5", "172.16.4.4", "172.31.255.1", "169.254.3.3", "fe80::1", "fd12:3456::1", "::ffff:192.168.0.2"] {
            XCTAssertTrue(IPAddress(ip)!.isLocal, ip)
        }
        for ip in ["8.8.8.8", "172.32.0.1", "1.1.1.1", "2606:4700::1111", "::ffff:8.8.8.8"] {
            XCTAssertFalse(IPAddress(ip)!.isLocal, ip)
        }
        XCTAssertNil(LANGuard.validateName("studio.local"))
        XCTAssertNil(LANGuard.validateName("192.168.1.9"))
        XCTAssertNotNil(LANGuard.validateName("8.8.8.8"))
    }

    // MARK: VNC password

    func testVNCPasswordResponse() throws {
        // Reference: openssl enc -des-ecb with the bit-reversed key of "password".
        let challenge = Array(0..<16).map(UInt8.init)
        let response = try RFBAuth.vncResponse(challenge: challenge, password: "password")
        XCTAssertEqual(response.map { String(format: "%02x", $0) }.joined(),
                       "b866924125c8eebb9debc1db61c538e2")
    }

    // MARK: ZRLE

    /// Builds a ZRLE rect: a 70×3 area, so two tiles (64 + 6 wide) — the
    /// first solid, the second packed-palette — and checks the pixels.
    func testZRLEDecodesSolidAndPackedPaletteTiles() throws {
        let red: [UInt8] = [0x00, 0x00, 0xFF]     // cpixel b,g,r
        let blue: [UInt8] = [0xFF, 0x00, 0x00]
        var tiles: [UInt8] = []
        tiles += [1] + red                          // tile 1: solid red 64×3
        tiles += [2] + red + blue                   // tile 2: 2-colour palette, 6×3, 1 bit/px
        tiles += [0b1010_1000, 0b0101_0100, 0b1111_1100]

        let decoder = ZRLEDecoder()
        let data = try decoder.inflate(ArraySlice(deflateSync(tiles)))
        XCTAssertEqual(data, tiles)

        let fb = Framebuffer(width: 80, height: 4)
        try decoder.decode(data, x: 2, y: 1, w: 70, h: 3, format: .full, into: fb)
        let px = { (x: Int, y: Int) in fb.pixels[y * fb.width + x] & 0x00FF_FFFF }
        XCTAssertEqual(px(2, 1), 0xFF0000)
        XCTAssertEqual(px(65, 3), 0xFF0000)
        // Tile 2 starts at x = 66.
        XCTAssertEqual(px(66, 1), 0x0000FF)
        XCTAssertEqual(px(67, 1), 0xFF0000)
        XCTAssertEqual(px(66, 2), 0xFF0000)
        XCTAssertEqual(px(67, 2), 0x0000FF)
        XCTAssertEqual(px(71, 3), 0x0000FF)
        // Untouched outside the rect.
        XCTAssertEqual(fb.pixels[0], 0xFF1A222C)
    }

    func testZRLEPlainAndPaletteRLE() throws {
        let green: [UInt8] = [0x00, 0xFF, 0x00]
        let white: [UInt8] = [0xFF, 0xFF, 0xFF]
        // 4×2 tile, plain RLE: 5 green then 3 white.
        var tile: [UInt8] = [128] + green + [4] + white + [2]
        let decoder = ZRLEDecoder()
        let fb = Framebuffer(width: 4, height: 4)
        try decoder.decode(tile, x: 0, y: 0, w: 4, h: 2, format: .full, into: fb)
        XCTAssertEqual(fb.pixels[4] & 0xFFFFFF, 0x00FF00)
        XCTAssertEqual(fb.pixels[5] & 0xFFFFFF, 0xFFFFFF)

        // Palette RLE: palette [green, white]; index 1 run 3, index 0 single, rest index 1.
        tile = [130] + green + white + [0x81, 2, 0x00, 0x81, 3]
        try decoder.decode(tile, x: 0, y: 2, w: 4, h: 2, format: .full, into: fb)
        XCTAssertEqual(fb.pixels[8] & 0xFFFFFF, 0xFFFFFF)
        XCTAssertEqual(fb.pixels[11] & 0xFFFFFF, 0x00FF00)
        XCTAssertEqual(fb.pixels[15] & 0xFFFFFF, 0xFFFFFF)
    }

    func testRGB565Expansion() {
        let white: [UInt8] = [0xFF, 0xFF]
        let v = white.withUnsafeBufferPointer { RFBPixelFormat.compact.pixel($0.baseAddress!, cpixel: true) }
        XCTAssertEqual(v & 0xFFFFFF, 0xFFFFFF)
    }

    // MARK: Keyboard

    @MainActor
    func testStickyModifiers() {
        let m = ModifierState()
        m.modifierDown(.control); m.modifierUp(.control)          // tap → latched
        XCTAssertTrue(m.isActive(.control))
        XCTAssertEqual(m.consume(), [.control])                    // used once
        XCTAssertFalse(m.isActive(.control))

        m.modifierDown(.shift); m.modifierUp(.shift)
        m.modifierDown(.shift); m.modifierUp(.shift)               // double tap → locked
        XCTAssertTrue(m.isLocked(.shift))
        _ = m.consume()
        XCTAssertTrue(m.isActive(.shift))                          // survives a key press

        m.modifierDown(.command)                                   // chord
        _ = m.consume()
        m.modifierUp(.command)
        XCTAssertFalse(m.isActive(.command))
    }

    @MainActor
    func testKeysyms() {
        XCTAssertEqual(Keysym.character("a"), 0x61)
        XCTAssertEqual(Keysym.character("é"), 0xE9)
        XCTAssertEqual(Keysym.character("€"), 0x0100_20AC)
        XCTAssertEqual(Keysym.function(12), 0xFFC9)
    }

    // MARK: Posture

    func testPosture() {
        let outer = CGSize(width: 466, height: 678)
        let inner = CGSize(width: 669, height: 951)
        let innerLandscape = CGSize(width: 951, height: 669)
        XCTAssertEqual(Posture.from(size: outer, hinge: .closed), .folded)
        XCTAssertEqual(Posture.from(size: inner, hinge: .partiallyOpen), .deck)
        XCTAssertEqual(Posture.from(size: inner, hinge: .fullyOpen), .deck)
        XCTAssertEqual(Posture.from(size: innerLandscape, hinge: .fullyOpen), .flat)
        // Half-open sideways is book posture: the crease is vertical, no deck split.
        XCTAssertEqual(Posture.from(size: innerLandscape, hinge: .partiallyOpen), .flat)
        XCTAssertEqual(Posture.from(size: inner, hinge: nil), .deck)
        XCTAssertEqual(Posture.from(size: inner, hinge: .unknown), .deck)
    }

    // MARK: Helpers

    private func deflateSync(_ input: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        deflateInit_(&stream, Z_DEFAULT_COMPRESSION, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        var source = input
        var out = [UInt8](repeating: 0, count: input.count + 128)
        source.withUnsafeMutableBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                stream.next_in = src.baseAddress
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(dst.count)
                deflate(&stream, Z_SYNC_FLUSH)
            }
        }
        let produced = out.count - Int(stream.avail_out)
        deflateEnd(&stream)
        return Array(out.prefix(produced))
    }
}
