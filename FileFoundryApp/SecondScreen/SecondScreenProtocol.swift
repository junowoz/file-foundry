import Foundation

/// Wire format of docs/second-screen-protocol.md (v2). Everything here is pure.
enum SSProtocol {
    static let version = 2
    static let port: UInt16 = 47321
    static let bonjourType = "_ffscreen._tcp"
    /// Limit after AUTH succeeded.
    static let maxFrameLength = 8 * 1024 * 1024
    /// Limit before AUTH succeeded (checked before anything is allocated).
    static let maxPreAuthFrameLength = 4 * 1024
    static let authTimeout: TimeInterval = 5
    /// A streaming session ends after this long without any inbound frame.
    static let idleTimeout: TimeInterval = 8
    static let maxPreAuthConnections = 4
    static let maxPreAuthPerAddress = 2
    static let maxNameBytes = 64
}

enum SSMessageType: UInt8, Sendable {
    case hello = 0x01
    case challenge = 0x02
    case auth = 0x03
    case welcome = 0x04
    case config = 0x05
    case video = 0x06
    case input = 0x07
    case keyframeRequest = 0x08
    case ping = 0x09
    case pong = 0x0A
    case stats = 0x0B
    case bye = 0x0F
}

struct SSFrame: Equatable, Sendable {
    var type: UInt8
    var payload: Data
}

enum SSFramingError: Error, Equatable {
    case invalidLength(Int)
    case malformed
}

enum SSFraming {
    /// `u32 length` (type byte + payload, big-endian) · `u8 type` · `payload`.
    static func encode(type: UInt8, payload: Data) -> Data {
        var out = Data()
        out.reserveCapacity(5 + payload.count)
        out.appendBE(UInt32(payload.count + 1))
        out.append(type)
        out.append(payload)
        return out
    }

    static func encode(_ type: SSMessageType, _ payload: Data = Data()) -> Data {
        encode(type: type.rawValue, payload: payload)
    }
}

/// Incremental decoder: feed raw socket bytes, pull complete frames.
struct SSFrameDecoder: Sendable {
    private var buffer = Data()
    /// Largest accepted `length`. Starts at the pre-auth cap; raise it after authentication.
    var maxLength = SSProtocol.maxPreAuthFrameLength

    init(maxLength: Int = SSProtocol.maxPreAuthFrameLength) { self.maxLength = maxLength }

    mutating func append(_ data: Data) { buffer.append(data) }

    var bufferedByteCount: Int { buffer.count }

    /// Returns the next full frame, nil if more bytes are needed, throws on a bad length.
    mutating func next() throws -> SSFrame? {
        guard buffer.count >= 4 else { return nil }
        let base = buffer.startIndex
        let length = Int(buffer.readU32BE(at: base))
        guard length >= 1, length <= maxLength else {
            throw SSFramingError.invalidLength(length)
        }
        guard buffer.count >= 4 + length else { return nil }
        let type = buffer[base + 4]
        let payload = Data(buffer[(base + 5)..<(base + 4 + length)])
        buffer.removeSubrange(base..<(base + 4 + length))
        return SSFrame(type: type, payload: payload)
    }
}

// MARK: - Messages

struct SSHello: Codable, Equatable, Sendable {
    var v: Int
    var deviceId: String
    var name: String
    var width: Int
    var height: Int
    var densityDpi: Int
    var codecs: [String]
    var maxFps: Int
    var clientNonce: String
    var clientPub: String

    var clientNonceData: Data? {
        guard let d = Data(base64Encoded: clientNonce), d.count == 32 else { return nil }
        return d
    }

    var clientPubData: Data? {
        guard let d = Data(base64Encoded: clientPub), d.count == 32 else { return nil }
        return d
    }

    var supportsHEVC: Bool { codecs.contains { $0.lowercased() == "hevc" } }

    /// Field validation of the v2 "Limits" paragraph. Anything else gets `BYE "hello"`.
    var isValid: Bool {
        v == SSProtocol.version
            && !deviceId.isEmpty && deviceId.utf8.count <= 64
            && deviceId != SSKeychainKeyStore.hostIdAccount
            && codecs.count <= 8 && codecs.allSatisfy { ["hevc", "avc"].contains($0.lowercased()) }
            && (1...240).contains(maxFps)
            && (320...8192).contains(width) && (320...8192).contains(height)
            && (72...1000).contains(densityDpi)
            && clientNonceData != nil && clientPubData != nil
    }

    /// `name` longer than 64 UTF-8 bytes is truncated (on a character boundary), not rejected.
    func normalized() -> SSHello {
        var h = self
        h.name = name.truncatedUTF8(maxBytes: SSProtocol.maxNameBytes)
        return h
    }
}

/// First look at a HELLO: only the version, so a v1 client gets `BYE "version"` whatever else it sent.
struct SSHelloVersion: Decodable { var v: Int }

struct SSChallenge: Codable, Equatable, Sendable {
    var v: Int
    var hostNonce: String
    var hostPub: String
    var hostId: String
    var hostName: String
    var mode: String   // "pair" | "known"
}

struct SSAuth: Codable, Equatable, Sendable {
    var proof: String
}

struct SSWelcome: Codable, Equatable, Sendable {
    var deviceKey: String?
}

struct SSConfig: Codable, Equatable, Sendable {
    var codec: String   // "hevc" | "avc"
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int
}

struct SSClientStats: Codable, Equatable, Sendable {
    var decodedFps: Double
    var dropped: Int
    var latencyMs: Double
}

/// Flags byte of a VIDEO message.
struct SSVideoFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let keyframe = SSVideoFlags(rawValue: 1 << 0)
    static let codecConfig = SSVideoFlags(rawValue: 1 << 1)
}

enum SSVideoPacket {
    static func encode(ptsMicros: UInt64, flags: SSVideoFlags, annexB: Data) -> Data {
        var out = Data()
        out.reserveCapacity(9 + annexB.count)
        out.appendBE(ptsMicros)
        out.append(flags.rawValue)
        out.append(annexB)
        return out
    }

    static func decode(_ data: Data) -> (ptsMicros: UInt64, flags: SSVideoFlags, annexB: Data)? {
        guard data.count >= 9 else { return nil }
        let b = data.startIndex
        return (data.readU64BE(at: b), SSVideoFlags(rawValue: data[b + 8]), Data(data[(b + 9)...]))
    }
}

// MARK: - Input

struct SSInputEvent: Equatable, Sendable {
    enum Kind: UInt8, Sendable { case down = 0, move, up, scroll, rightClick, cancel }
    var kind: Kind
    var pointerId: UInt8
    var x: Float
    var y: Float
    var dx: Float
    var dy: Float

    static let encodedSize = 18

    init(kind: Kind, pointerId: UInt8 = 0, x: Float = 0, y: Float = 0, dx: Float = 0, dy: Float = 0) {
        self.kind = kind; self.pointerId = pointerId
        self.x = x; self.y = y; self.dx = dx; self.dy = dy
    }

    init?(decoding data: Data) {
        guard data.count == Self.encodedSize, let kind = Kind(rawValue: data[data.startIndex]) else { return nil }
        let b = data.startIndex
        self.init(kind: kind, pointerId: data[b + 1],
                  x: data.readF32BE(at: b + 2), y: data.readF32BE(at: b + 6),
                  dx: data.readF32BE(at: b + 10), dy: data.readF32BE(at: b + 14))
    }

    func encoded() -> Data {
        var d = Data()
        d.append(kind.rawValue); d.append(pointerId)
        d.appendBE(x.bitPattern); d.appendBE(y.bitPattern)
        d.appendBE(dx.bitPattern); d.appendBE(dy.bitPattern)
        return d
    }
}

/// Maps normalised stream coordinates onto the virtual display, clamped to its bounds.
enum SSInputMapper {
    static func point(x: Float, y: Float, in bounds: CGRect) -> CGPoint {
        let cx = clamp01(x), cy = clamp01(y)
        // Stay one point inside so the pointer never lands on a neighbouring display.
        let w = max(bounds.width - 1, 0), h = max(bounds.height - 1, 0)
        return CGPoint(x: bounds.minX + CGFloat(cx) * w, y: bounds.minY + CGFloat(cy) * h)
    }

    static func clamp01(_ v: Float) -> Float {
        v.isNaN ? 0 : min(max(v, 0), 1)
    }

    /// Scroll deltas are untrusted: drop NaN/inf and cap magnitude.
    static func scroll(_ v: Float) -> Int32 {
        guard v.isFinite else { return 0 }
        return Int32(min(max(v, -2000), 2000))
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readU32BE(at i: Index) -> UInt32 {
        (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    func readU64BE(at i: Index) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(self[i + k]) }
        return v
    }

    func readF32BE(at i: Index) -> Float { Float(bitPattern: readU32BE(at: i)) }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(); var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        self = out
    }
}

extension String {
    /// Longest prefix of whole characters that fits in `maxBytes` UTF-8 bytes.
    func truncatedUTF8(maxBytes: Int) -> String {
        if utf8.count <= maxBytes { return self }
        var out = ""
        var used = 0
        for ch in self {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch); used += n
        }
        return out
    }
}
