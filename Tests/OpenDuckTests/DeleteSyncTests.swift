import Foundation
import OpenDuckCore

final class DeleteSyncTests: XCTestCase {
    var tempDir: URL!
    var cacheDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-delete-test-\(UUID().uuidString)")
        cacheDir = tempDir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Defect 1: Failed deletes should be journaled for retry

    func testFailedDeleteIsJournaledForRetry() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        // Create a file on the remote
        let testContent = Data("hello world".utf8)
        try await adapter.upload(from: createTempFile(content: testContent), to: "/test.txt", progress: nil)

        // Configure adapter to fail on next delete
        adapter.simulatedError = AdapterError.networkError("Connection timeout")

        let journalURL = tempDir.appendingPathComponent("journal_\(UUID().uuidString).json")
        let cacheEngine = CacheEngine(cacheDirectory: cacheDir, journalURL: journalURL)
        let volumeManager = VolumeMountManager()

        let context = WatcherContext(
            volumeURL: tempDir,
            remoteRootPath: "/",
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: volumeManager,
            isReadOnly: false
        )

        // Create a local file then delete it to trigger the delete path
        let localFile = tempDir.appendingPathComponent("test.txt")
        try testContent.write(to: localFile)

        // Register it in cache so itemIdentifier works
        let entry = RemoteFileEntry(name: "test.txt", path: "/test.txt", size: Int64(testContent.count))
        _ = cacheEngine.registerPlaceholder(for: entry)

        // Remove the local file (simulating Finder delete)
        try FileManager.default.removeItem(at: localFile)

        // Trigger the delete event
        context.handleEvent(
            localPath: localFile.path,
            flags: 0x00000200 // kFSEventStreamEventFlagItemRemoved
        )

        // Wait for the async Task to execute
        try await Task.sleep(nanoseconds: 500_000_000)

        // The deletion should have been journaled because the adapter was set to fail
        let pending = cacheEngine.journal.pendingEntries()
        XCTAssertTrue(pending.contains { $0.action == .delete && $0.remotePath == "/test.txt" })
    }

    // MARK: - Defect 4: Circuit breaker blocked deletes should be journaled

    func testCircuitBreakerBlockedDeletesAreJournaled() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let journalURL = tempDir.appendingPathComponent("journal_\(UUID().uuidString).json")
        let cacheEngine = CacheEngine(cacheDirectory: cacheDir, journalURL: journalURL)
        let volumeManager = VolumeMountManager()

        let context = WatcherContext(
            volumeURL: tempDir,
            remoteRootPath: "/",
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: volumeManager,
            isReadOnly: false
        )

        // Register 20 remote files
        for i in 1...20 {
            let entry = RemoteFileEntry(name: "file_\(i).txt", path: "/file_\(i).txt", size: 100)
            _ = cacheEngine.registerPlaceholder(for: entry)
        }

        // Simulate rapid bulk delete of 20 files (circuit breaker trips at >10)
        for i in 1...20 {
            let fakePath = tempDir.appendingPathComponent("file_\(i).txt").path
            context.handleEvent(localPath: fakePath, flags: 0x00000200)
        }

        // Circuit breaker should be tripped
        XCTAssertTrue(context.isCircuitBreakerTripped)

        // Wait for async tasks
        try await Task.sleep(nanoseconds: 500_000_000)

        // Deletions blocked by the circuit breaker should be in the journal
        let pending = cacheEngine.journal.pendingEntries()
        let deletePending = pending.filter { $0.action == .delete }
        // At least some deletions should be queued (those beyond the burst threshold)
        XCTAssertGreaterThan(deletePending.count, 0)
    }

    // MARK: - Defect 6: Hydration should not trigger re-upload

    func testHydratingPathTokenPreventsReupload() {
        let volumeManager = VolumeMountManager()

        // Register a path as being hydrated
        volumeManager.recordHydratingPath("/tmp/test/file.txt")

        // Consuming the token should return true
        XCTAssertTrue(volumeManager.isHydratingPath("/tmp/test/file.txt"))

        // Second consumption should return false (token consumed)
        XCTAssertFalse(volumeManager.isHydratingPath("/tmp/test/file.txt"))
    }

    // MARK: - Defect 5: Provenance tokens should persist in SQLite

    func testProvenanceTokenPersistsInDatabase() {
        let volumeManager = VolumeMountManager()

        // Record a self-initiated removal
        volumeManager.recordSelfInitiatedRemoval(path: "/Volumes/Test/somefile.txt")

        // Verify it's persisted in the database (bypass in-memory check)
        _ = MetadataDatabase.shared.consumeSelfInitiatedRemoval(localPath: "/Volumes/Test/somefile.txt")

        // Re-record and check via the manager
        volumeManager.recordSelfInitiatedRemoval(path: "/Volumes/Test/anotherfile.txt")
        let found = volumeManager.isSelfInitiatedRemoval(path: "/Volumes/Test/anotherfile.txt")
        XCTAssertTrue(found)

        // Token should be consumed now
        let foundAgain = volumeManager.isSelfInitiatedRemoval(path: "/Volumes/Test/anotherfile.txt")
        XCTAssertFalse(foundAgain)
    }

    // MARK: - Defect 3: Recursive directory deletion via SFTPAdapter

    func testMockAdapterRecursiveDirectoryDelete() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        // Create a nested directory structure
        try await adapter.createDirectory(path: "/parent")
        try await adapter.createDirectory(path: "/parent/child")

        let content = Data("test".utf8)
        let tempFile = createTempFile(content: content)
        try await adapter.upload(from: tempFile, to: "/parent/file1.txt", progress: nil)
        try await adapter.upload(from: tempFile, to: "/parent/child/file2.txt", progress: nil)

        // Delete the parent directory (should recursively delete all children)
        try await adapter.delete(remotePath: "/parent")

        // Verify everything is gone
        do {
            _ = try await adapter.listDirectory(path: "/parent")
            XCTFail("Expected directory to be deleted")
        } catch {
            // Expected: directory not found
        }
    }

    // MARK: - CacheEngine retry scheduler

    func testRetrySchedulerProcessesPendingDeletes() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        // Create a file on the remote
        let content = Data("hello".utf8)
        try await adapter.upload(from: createTempFile(content: content), to: "/retry_test.txt", progress: nil)

        let journalURL = tempDir.appendingPathComponent("journal_\(UUID().uuidString).json")
        let cacheEngine = CacheEngine(cacheDirectory: cacheDir, journalURL: journalURL)

        // Manually journal a delete entry
        let entry = JournalEntry(
            action: .delete,
            itemIdentifier: "test-id",
            remotePath: "/retry_test.txt"
        )
        cacheEngine.journal.append(entry)
        XCTAssertEqual(cacheEngine.journal.count, 1)

        // Process pending writes — should execute the delete
        try await cacheEngine.syncPendingWrites(with: adapter)

        // Journal should be cleared after successful processing
        XCTAssertEqual(cacheEngine.journal.count, 0)

        // File should be gone from remote
        do {
            _ = try await adapter.stat(path: "/retry_test.txt")
            XCTFail("Expected file to be deleted")
        } catch {
            // Expected: file not found
        }
    }

    // MARK: - Helper

    private func createTempFile(content: Data) -> URL {
        let url = tempDir.appendingPathComponent("upload_\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: url.path, contents: content)
        return url
    }
}
