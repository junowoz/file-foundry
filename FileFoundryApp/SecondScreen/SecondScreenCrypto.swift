import CryptoKit
import Foundation
import Security

/// Key schedule of the Second Screen protocol (v2).
///
/// `shared = X25519(ownPrivate, peerPublic)`;
/// `okm = HKDF-SHA256(ikm: shared ‖ secret, salt: clientNonce ‖ hostNonce ‖ clientPub ‖ hostPub,
/// info: "ffscreen v2", 96 bytes)` split into `authKey ‖ h2cKey ‖ c2hKey`. Everything is raw bytes.
struct SSSessionKeys: Sendable {
    let authKey: SymmetricKey
    let hostToClient: SymmetricKey
    let clientToHost: SymmetricKey

    static let info = Data("ffscreen v2".utf8)

    init(shared: Data, secret: Data, clientNonce: Data, hostNonce: Data, clientPub: Data, hostPub: Data) {
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared + secret),
            salt: clientNonce + hostNonce + clientPub + hostPub,
            info: Self.info,
            outputByteCount: 96)
        let bytes = okm.withUnsafeBytes { Data($0) }
        authKey = SymmetricKey(data: bytes[0..<32])
        hostToClient = SymmetricKey(data: bytes[32..<64])
        clientToHost = SymmetricKey(data: bytes[64..<96])
    }

    /// `HMAC-SHA256(authKey, "auth" ‖ deviceId ‖ clientNonce ‖ hostNonce ‖ clientPub ‖ hostPub)`
    func proof(deviceId: String, clientNonce: Data, hostNonce: Data, clientPub: Data, hostPub: Data) -> Data {
        var message = Data("auth".utf8)
        message.append(Data(deviceId.utf8))
        message.append(clientNonce)
        message.append(hostNonce)
        message.append(clientPub)
        message.append(hostPub)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: authKey))
    }

    /// Constant-time proof check.
    func verify(proof: Data, deviceId: String, clientNonce: Data, hostNonce: Data, clientPub: Data, hostPub: Data) -> Bool {
        let expected = self.proof(deviceId: deviceId, clientNonce: clientNonce, hostNonce: hostNonce,
                                  clientPub: clientPub, hostPub: hostPub)
        return SSConstantTime.equal(expected, proof)
    }
}

/// Ephemeral X25519 (CryptoKit). The all-zero shared secret (low-order peer key) is rejected.
enum SSX25519 {
    static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublic: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let bytes = secret.withUnsafeBytes { Data($0) }
        guard bytes.count == 32, bytes.contains(where: { $0 != 0 }) else { throw SSCryptoError.weakSharedSecret }
        return bytes
    }
}

/// `SecRandomCopyBytes` with its status checked; a failure aborts the session.
enum SSRandom {
    static func bytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SSCryptoError.randomFailed(status) }
        return data
    }
}

enum SSConstantTime {
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

enum SSCryptoError: Error { case badLength, authenticationFailed, weakSharedSecret, randomFailed(OSStatus) }

/// `nonce = 4 zero bytes ‖ u64 big-endian counter`
enum SSNonce {
    static func make(counter: UInt64) -> Data {
        var d = Data(count: 4)
        d.appendBE(counter)
        return d
    }
}

/// One direction of the encrypted channel with its own counter (starting at 0).
/// Not thread-safe: confine to one queue.
struct SSSealer {
    private let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// Returns `ciphertext ‖ tag(16)` and advances the counter. AAD is the 1-byte message type.
    mutating func seal(_ plaintext: Data, type: UInt8) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: SSNonce.make(counter: counter))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data([type]))
        counter += 1
        return box.ciphertext + box.tag
    }
}

struct SSOpener {
    private let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// The counter is implicit (not transmitted), so a dropped or replayed message
    /// fails authentication and the caller closes the connection.
    mutating func open(_ sealed: Data, type: UInt8) throws -> Data {
        guard sealed.count >= 16 else { throw SSCryptoError.badLength }
        let cut = sealed.endIndex - 16
        let nonce = try AES.GCM.Nonce(data: SSNonce.make(counter: counter))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed[sealed.startIndex..<cut], tag: sealed[cut...])
        do {
            let plain = try AES.GCM.open(box, using: key, authenticating: Data([type]))
            counter += 1
            return plain
        } catch {
            throw SSCryptoError.authenticationFailed
        }
    }
}
