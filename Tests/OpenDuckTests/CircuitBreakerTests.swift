import Foundation
import Testing
@testable import OpenDuckCore

@Suite final class CircuitBreakerTests {
    var tempDir: URL

    init() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-breaker-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func circuitBreakerBurstAndSustainedTriggers() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let cacheDir = tempDir.appendingPathComponent("cache")
        let cacheEngine = CacheEngine(cacheDirectory: cacheDir)
        let volumeManager = VolumeMountManager()

        final class StatusBox: @unchecked Sendable {
            var message: String?
            private let lock = NSLock()
            func set(_ msg: String) {
                lock.lock()
                message = msg
                lock.unlock()
            }
            func get() -> String? {
                lock.lock()
                defer { lock.unlock() }
                return message
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
                statusBox.set(msg)
            }
        )

        #expect(!context.isCircuitBreakerTripped)

        // Simulate 15 rapid deletions in < 1 second to trigger burst breaker
        for i in 1...15 {
            let fakePath = tempDir.appendingPathComponent("victim_\(i).txt").path
            context.handleEvent(localPath: fakePath, flags: 0x00000200) // kFSEventStreamEventFlagItemRemoved
        }

        #expect(context.isCircuitBreakerTripped)
        #expect(statusBox.get()?.contains("CIRCUIT BREAKER TRIPPED") == true)

        // Verify divergence event was recorded in DB
        let events = MetadataDatabase.shared.allDivergenceEvents()
        #expect(events.contains { $0.path == "MASS_DELETION_BREAKER" })

        // Test explicit reset
        context.resetCircuitBreaker()
        #expect(!context.isCircuitBreakerTripped)
    }
}
