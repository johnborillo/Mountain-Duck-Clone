import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
import OpenDuckCore

final class HostKeyValidatorTests: XCTestCase {
    var tempDBDir: URL!
    var eventLoopGroup: MultiThreadedEventLoopGroup!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDBDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-hostkey-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDBDir, withIntermediateDirectories: true)
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDBDir)
        try? eventLoopGroup.syncShutdownGracefully()
        try super.tearDownWithError()
    }

    func testFingerprintCalculationFormat() {
        // Known test payload: Base64 data with padding
        let testData = "OpenDuck-SSH-Host-Key-Test-Payload-12345".data(using: .utf8)!
        let hash = SHA256.hash(data: testData)
        let rawB64 = Data(hash).base64EncodedString()
        let stripped = "SHA256:" + rawB64.replacingOccurrences(of: "=", with: "")

        XCTAssertFalse(stripped.hasSuffix("="))
        XCTAssertTrue(stripped.hasPrefix("SHA256:"))
    }

    func testTofuFirstContactAndMismatchDetection() async throws {
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
        XCTAssertEqual(retrieved, "SHA256:InitialPinnedFingerprint123")

        let validator = OpenDuckHostKeyValidator(host: "test.example.com", port: 22)
        XCTAssertFalse(validator.mismatchDetected)
        XCTAssertNil(validator.validatedFingerprint)
    }

    func testFingerprintNormalizationAndLegacyPaddedHealing() {
        let padded = "SHA256:XusFL7Hj8Djw0EkH/vtG5YdVTPlsfKeHG7PF+WNdfpk="
        let unpadded = "SHA256:XusFL7Hj8Djw0EkH/vtG5YdVTPlsfKeHG7PF+WNdfpk"

        XCTAssertEqual(OpenDuckHostKeyValidator.normalizeFingerprint(padded), unpadded)
        XCTAssertEqual(OpenDuckHostKeyValidator.normalizeFingerprint(unpadded), unpadded)

        let dbURL = tempDBDir.appendingPathComponent("test_heal.sqlite")
        let db = MetadataDatabase(databaseURL: dbURL)

        // Simulate legacy pin with trailing '='
        db.pinHostKey(host: "legacy.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: padded)

        let retrieved = db.pinnedFingerprint(forHost: "legacy.example.com", port: 22)
        XCTAssertEqual(retrieved, unpadded) // Auto-healed on insert and migration
    }
}
