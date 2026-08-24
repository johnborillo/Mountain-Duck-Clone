import Foundation
import NIOCore
import NIOSSH
import Crypto
import Citadel

public struct HostKeyMismatchError: Error, CustomStringConvertible, Sendable {
    public let host: String
    public let port: Int
    public let expectedFingerprint: String
    public let receivedFingerprint: String

    public var description: String {
        "HOST KEY MISMATCH for \(host):\(port)! Expected: \(expectedFingerprint), Received: \(receivedFingerprint)"
    }
}

/// Validates remote SSH server host keys using Trust-On-First-Use (TOFU) with persistent SHA-256 fingerprint pinning.
public final class OpenDuckHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    public let host: String
    public let port: Int
    public let onPin: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var _validatedFingerprint: String?
    private var _mismatchDetected: Bool = false
    private var _expectedFingerprint: String?

    public var validatedFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return _validatedFingerprint
    }

    public var mismatchDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _mismatchDetected
    }

    public var expectedFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return _expectedFingerprint
    }

    public init(host: String, port: Int, onPin: (@Sendable (String) -> Void)? = nil) {
        self.host = host
        self.port = port
        self.onPin = onPin
    }

    public static func normalizeFingerprint(_ fp: String) -> String {
        var clean = fp.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasSuffix("=") {
            clean.removeLast()
        }
        return clean
    }

    public func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let openSSHKey = String(openSSHPublicKey: hostKey)
        let parts = openSSHKey.split(separator: " ")
        guard parts.count > 1, let rawData = Data(base64Encoded: String(parts[1])) else {
            validationCompletePromise.fail(AdapterError.authenticationFailed("Malformed or unparseable host key for \(host):\(port)"))
            return
        }

        let keyType = parts.first.map(String.init) ?? "unknown"
        let hash = SHA256.hash(data: rawData)
        // Standard OpenSSH format: SHA256 base64 digest with trailing '=' padding removed
        let rawBase64 = Data(hash).base64EncodedString()
        let fingerprint = Self.normalizeFingerprint("SHA256:" + rawBase64)

        lock.lock()
        _validatedFingerprint = fingerprint
        lock.unlock()

        let existingPinned = MetadataDatabase.shared.pinnedFingerprint(forHost: host, port: port)

        if let pinned = existingPinned {
            let normalizedPinned = Self.normalizeFingerprint(pinned)
            if normalizedPinned == fingerprint {
                // Key matches pinned fingerprint!
                // If legacy DB stored the fingerprint with trailing '=', heal/update it to canonical format
                if pinned != fingerprint {
                    MetadataDatabase.shared.pinHostKey(
                        host: host,
                        port: port,
                        keyType: keyType,
                        fingerprint: fingerprint
                    )
                }
                validationCompletePromise.succeed(())
            } else {
                // Host key mismatch! Possible MITM attack -> Reject immediately
                lock.lock()
                _mismatchDetected = true
                _expectedFingerprint = normalizedPinned
                lock.unlock()

                print("🛑 [OpenDuck Security] HOST KEY MISMATCH for \(host):\(port)!")
                print("   Expected pinned: \(normalizedPinned)")
                print("   Presented key:   \(fingerprint)")
                validationCompletePromise.fail(HostKeyMismatchError(
                    host: host,
                    port: port,
                    expectedFingerprint: normalizedPinned,
                    receivedFingerprint: fingerprint
                ))
            }
        } else {
            // First contact (TOFU) -> Pin fingerprint and accept
            MetadataDatabase.shared.pinHostKey(
                host: host,
                port: port,
                keyType: keyType,
                fingerprint: fingerprint
            )
            print("🛡️ [OpenDuck Security] Pinned new host key for \(host):\(port): \(fingerprint)")
            onPin?(fingerprint)
            validationCompletePromise.succeed(())
        }
    }
}
