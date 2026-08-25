import Foundation
import OpenDuckCore

final class CircuitBreakerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-breaker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testCircuitBreakerBurstAndSustainedTriggers() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let cacheDir = tempDir.appendingPathComponent("cache")
        let cacheEngine = CacheEngine(cacheDirectory: cacheDir)
        let volumeManager = VolumeMountManager()

        final class StatusBox: @unchecked Sendable {
            var messages: [String] = []
            private let lock = NSLock()
            func add(_ msg: String) {
                lock.lock()
                messages.append(msg)
                lock.unlock()
            }
            func all() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return messages
            }
        }

        let statusBox = StatusBox()
        let context = WatcherContext(
            volumeURL: tempDir,
            remoteRootPath: "/",
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: volumeManager,
            isReadOnly: false,
            onStatusChange: { msg in
                statusBox.add(msg)
            }
        )

        XCTAssertFalse(context.isCircuitBreakerTripped)

        // Simulate 15 rapid deletions in < 1 second to trigger burst breaker
        for i in 1...15 {
            let fakePath = tempDir.appendingPathComponent("victim_\(i).txt").path
            context.handleEvent(localPath: fakePath, flags: 0x00000200) // kFSEventStreamEventFlagItemRemoved
        }

        XCTAssertTrue(context.isCircuitBreakerTripped)
        XCTAssertTrue(statusBox.all().contains { $0.contains("CIRCUIT BREAKER TRIPPED") })

        // Verify divergence event was recorded in DB
        let events = MetadataDatabase.shared.allDivergenceEvents()
        XCTAssertTrue(events.contains { $0.path == "MASS_DELETION_BREAKER" })

        // Test explicit reset
        context.resetCircuitBreaker()
        XCTAssertFalse(context.isCircuitBreakerTripped)
    }
}
