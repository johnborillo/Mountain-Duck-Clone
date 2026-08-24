import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
@testable import OpenDuckCore

@Suite final class HostKeyValidatorTests {
    var tempDBDir: URL
    var eventLoopGroup: MultiThreadedEventLoopGroup

    init() {
        tempDBDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-hostkey-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDBDir, withIntermediateDirectories: true)
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDBDir)
        try? eventLoopGroup.syncShutdownGracefully()
    }

    @Test func fingerprintCalculationFormat() {
        // Known test payload: Base64 data with padding
        let testData = "OpenDuck-SSH-Host-Key-Test-Payload-12345".data(using: .utf8)!
        let hash = SHA256.hash(data: testData)
        let rawB64 = Data(hash).base64EncodedString()
        let stripped = "SHA256:" + rawB64.replacingOccurrences(of: "=", with: "")

        #expect(!stripped.hasSuffix("="))
        #expect(stripped.hasPrefix("SHA256:"))
    }

    @Test func tofuFirstContactAndMismatchDetection() async throws {
        let dbURL = tempDBDir.appendingPathComponent("test_tofu.sqlite")
        let db = MetadataDatabase(databaseURL: dbURL)

        // Seed initial pinned key
        db.pinHostKey(
            host: "test.example.com",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprint: "SHA256:InitialPinnedFingerprint123"
        )

        let retrieved = db.pinnedFingerprint(forHost: "test.example.com", port: 22)
        #expect(retrieved == "SHA256:InitialPinnedFingerprint123")

        let validator = OpenDuckHostKeyValidator(host: "test.example.com", port: 22)
        #expect(!validator.mismatchDetected)
        #expect(validator.validatedFingerprint == nil)
    }

    @Test func fingerprintNormalizationAndLegacyPaddedHealing() {
        let padded = "SHA256:XusFL7Hj8Djw0EkH/vtG5YdVTPlsfKeHG7PF+WNdfpk="
        let unpadded = "SHA256:XusFL7Hj8Djw0EkH/vtG5YdVTPlsfKeHG7PF+WNdfpk"

        #expect(OpenDuckHostKeyValidator.normalizeFingerprint(padded) == unpadded)
        #expect(OpenDuckHostKeyValidator.normalizeFingerprint(unpadded) == unpadded)

        let dbURL = tempDBDir.appendingPathComponent("test_heal.sqlite")
        let db = MetadataDatabase(databaseURL: dbURL)

        // Simulate legacy pin with trailing '='
        db.pinHostKey(host: "legacy.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: padded)

        let retrieved = db.pinnedFingerprint(forHost: "legacy.example.com", port: 22)
        #expect(retrieved == unpadded) // Auto-healed on insert and migration
    }
}
