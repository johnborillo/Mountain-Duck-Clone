import Foundation
import OpenDuckCore

final class DiagnosticsExporterTests: XCTestCase {
    func testReportIsReadableAndRedactsSecretLikePaths() throws {
        let profile = ServerProfile(
            name: "Support SFTP",
            host: "example.test",
            username: "alice",
            privateKeyPath: "/Users/alice/.ssh/id_ed25519"
        )
        let localURL = URL(fileURLWithPath: "/Users/alice/Library/Caches/OpenDuck/secret.txt")
        let operation = JournalEntry(action: .upload, itemIdentifier: "item-1", localFileURL: localURL, remotePath: "/docs/secret.txt")

        let data = try DiagnosticsExporter.makeReport(
            profiles: [profile],
            cacheStats: CacheStatistics(dirtyItems: 1),
            pendingOperations: [operation],
            conflicts: []
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("Support SFTP"))
        XCTAssertTrue(text.contains("secret.txt"))
        XCTAssertFalse(text.contains("id_ed25519"))
        XCTAssertFalse(text.contains("/Users/alice/Library/Caches/OpenDuck"))
    }
}
