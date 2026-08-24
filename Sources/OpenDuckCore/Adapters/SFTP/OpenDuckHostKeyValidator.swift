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
    public private(set) var validatedFingerprint: String?
    public private(set) var mismatchDetected: Bool = false
    public private(set) var expectedFingerprint: String?

    public init(host: String, port: Int, onPin: (@Sendable (String) -> Void)? = nil) {
        self.host = host
        self.port = port
        self.onPin = onPin
    }

    public func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let openSSHKey = String(openSSHPublicKey: hostKey)
        let parts = openSSHKey.split(separator: " ")
        let keyType = parts.first.map(String.init) ?? "unknown"
        let b64 = parts.count > 1 ? String(parts[1]) : ""
        let rawData = Data(base64Encoded: b64) ?? Data(openSSHKey.utf8)
        let hash = SHA256.hash(data: rawData)
        let fingerprint = "SHA256:" + Data(hash).base64EncodedString()
        self.validatedFingerprint = fingerprint

        let existingPinned = MetadataDatabase.shared.pinnedFingerprint(forHost: host, port: port)

        if let pinned = existingPinned {
            if pinned == fingerprint {
                // Key matches pinned fingerprint -> Accept
                validationCompletePromise.succeed(())
            } else {
                // Host key mismatch! Possible MITM attack -> Reject immediately
                self.mismatchDetected = true
                self.expectedFingerprint = pinned
                print("🛑 [OpenDuck Security] HOST KEY MISMATCH for \(host):\(port)!")
                print("   Expected pinned: \(pinned)")
                print("   Presented key:   \(fingerprint)")
                validationCompletePromise.fail(HostKeyMismatchError(
                    host: host,
                    port: port,
                    expectedFingerprint: pinned,
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
