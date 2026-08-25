import Foundation
import OpenDuckCore

final class CacheEngineTests: XCTestCase {
    var tempCacheDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempCacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-cache-unit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempCacheDir)
        try super.tearDownWithError()
    }

    func testPlaceholderRegistration() {
        let engine = CacheEngine(cacheDirectory: tempCacheDir)
        let entry = RemoteFileEntry(name: "test.txt", path: "/data/test.txt", size: 1024)

        let cached = engine.registerPlaceholder(for: entry)
        XCTAssertEqual(cached.localFileName, "test.txt")
        XCTAssertEqual(cached.state, .placeholder)
        XCTAssertEqual(cached.fileSize, 1024)
    }

    func testHydrationAndDirtySync() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()
        adapter.seedFile(path: "/data/config.json", content: "{\"version\": 1}")

        let engine = CacheEngine(cacheDirectory: tempCacheDir)
        let fileId = engine.itemIdentifier(for: "/data/config.json")

        // 1. Hydrate
        let localURL = try await engine.getOrHydrate(
            itemIdentifier: fileId,
            remotePath: "/data/config.json",
            adapter: adapter
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        let initialContent = try String(contentsOf: localURL, encoding: .utf8)
        XCTAssertEqual(initialContent, "{\"version\": 1}")

        // 2. Modify locally & mark dirty
        let modifiedContent = "{\"version\": 2, \"updated\": true}"
        try modifiedContent.write(to: localURL, atomically: true, encoding: .utf8)
        engine.markDirty(itemIdentifier: fileId, newLocalURL: localURL)

        let stats = engine.statistics()
        XCTAssertEqual(stats.dirtyItems, 1)

        // 3. Sync pending writes
        try await engine.syncPendingWrites(with: adapter)

        let postSyncStats = engine.statistics()
        XCTAssertEqual(postSyncStats.dirtyItems, 0)

        // 4. Verify remote has updated data
        let verifyURL = tempCacheDir.appendingPathComponent("verify.json")
        try await adapter.download(remotePath: "/data/config.json", to: verifyURL, progress: nil)
        let remoteContent = try String(contentsOf: verifyURL, encoding: .utf8)
        XCTAssertEqual(remoteContent, modifiedContent)
    }

    func testLruEvictionPolicy() {
        let policy = LRUEvictionPolicy(maxCacheSizeBytes: 1000, lowWatermarkPercentage: 0.5)

        let now = Date()
        let oldDate = now.addingTimeInterval(-3600)

        let entry1 = CacheEntry(itemIdentifier: "1", remotePath: "/f1", localFileName: "f1", fileSize: 400, lastAccessedDate: oldDate, isPinned: false, state: .materialized)
        let entry2 = CacheEntry(itemIdentifier: "2", remotePath: "/f2", localFileName: "f2", fileSize: 400, lastAccessedDate: now, isPinned: false, state: .materialized)
        let entry3 = CacheEntry(itemIdentifier: "3", remotePath: "/f3", localFileName: "f3", fileSize: 400, lastAccessedDate: oldDate, isPinned: true, state: .materialized) // Pinned!

        let victims = policy.selectEntriesForEviction(from: [entry1, entry2, entry3])
        // Total = 1200 > 1000. Target = 500. Needs to free 700 bytes.
        // entry3 is pinned, so only entry1 (oldest) and entry2 are candidates.
        XCTAssertTrue(victims.contains { $0.itemIdentifier == "1" })
        XCTAssertFalse(victims.contains { $0.itemIdentifier == "3" }) // Pinned items must never be evicted
    }

    func testPurgeUnpinnedProtectsDirtyAndPinnedFiles() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()
        adapter.seedFile(path: "/data/clean.txt", content: "clean unpinned content")
        adapter.seedFile(path: "/data/pinned.txt", content: "pinned content")
        adapter.seedFile(path: "/data/dirty.txt", content: "initial dirty content")

        let engine = CacheEngine(cacheDirectory: tempCacheDir)

        let cleanId = engine.itemIdentifier(for: "/data/clean.txt")
        let pinnedId = engine.itemIdentifier(for: "/data/pinned.txt")
        let dirtyId = engine.itemIdentifier(for: "/data/dirty.txt")

        let cleanURL = try await engine.getOrHydrate(itemIdentifier: cleanId, remotePath: "/data/clean.txt", adapter: adapter)
        let pinnedURL = try await engine.getOrHydrate(itemIdentifier: pinnedId, remotePath: "/data/pinned.txt", adapter: adapter)
        let dirtyURL = try await engine.getOrHydrate(itemIdentifier: dirtyId, remotePath: "/data/dirty.txt", adapter: adapter)

        engine.setPinned(true, for: pinnedId)

        let unuploadedEdit = "UNSAVED LOCAL WORK - CRITICAL TO PRESERVE"
        try unuploadedEdit.write(to: dirtyURL, atomically: true, encoding: .utf8)
        engine.markDirty(itemIdentifier: dirtyId, newLocalURL: dirtyURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyURL.path))

        // Execute purge
        try engine.purgeUnpinned()

        // Clean unpinned file MUST be evicted
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanURL.path))

        // Pinned file MUST survive
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
        let pinnedContent = try String(contentsOf: pinnedURL, encoding: .utf8)
        XCTAssertEqual(pinnedContent, "pinned content")

        // Dirty (unuploaded) file MUST survive intact with dirty edits!
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyURL.path))
        let preservedDirtyContent = try String(contentsOf: dirtyURL, encoding: .utf8)
        XCTAssertEqual(preservedDirtyContent, unuploadedEdit)
    }

    func testLatestPendingUploadIsPersistedAndSupersedesOlderSave() throws {
        let journalURL = tempCacheDir.appendingPathComponent("journal.json")
        let engine = CacheEngine(cacheDirectory: tempCacheDir, journalURL: journalURL)
        let entry = RemoteFileEntry(name: "draft.txt", path: "/draft.txt", size: 4)
        let itemID = engine.registerPlaceholder(for: entry).itemIdentifier
        let localURL = engine.fileURL(for: itemID)
        FileManager.default.createFile(atPath: localURL.path, contents: Data("one".utf8))

        engine.markDirty(itemIdentifier: itemID, newLocalURL: localURL)
        try Data("two".utf8).write(to: localURL)
        engine.markDirty(itemIdentifier: itemID, newLocalURL: localURL)

        let restored = UploadJournal(persistenceURL: journalURL)
        let uploads = restored.pendingEntries().filter { $0.action == .upload }
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.remotePath, "/draft.txt")
    }

    func testMissingQueuedUploadIsRetainedForRecovery() async throws {
        let journalURL = tempCacheDir.appendingPathComponent("journal.json")
        let engine = CacheEngine(cacheDirectory: tempCacheDir, journalURL: journalURL)
        let entry = RemoteFileEntry(name: "draft.txt", path: "/draft.txt", size: 4)
        let itemID = engine.registerPlaceholder(for: entry).itemIdentifier
        let missingURL = tempCacheDir.appendingPathComponent("missing-content")
        engine.markDirty(itemIdentifier: itemID, newLocalURL: missingURL)

        let adapter = MockFileSystemAdapter()
        try await adapter.connect()
        do {
            try await engine.syncPendingWrites(with: adapter)
            XCTFail("Expected missing content to stop recovery")
        } catch {
            XCTAssertEqual(engine.journal.count, 1)
        }
    }

    func testEnqueueUploadStagesTransientSourceDurably() async throws {
        let journalURL = tempCacheDir.appendingPathComponent("journal-staged.json")
        let engine = CacheEngine(cacheDirectory: tempCacheDir, journalURL: journalURL)
        let sourceURL = tempCacheDir.appendingPathComponent("finder-transient.txt")
        try Data("durable snapshot".utf8).write(to: sourceURL)

        try engine.enqueueUpload(itemIdentifier: "stable-id", remotePath: "/staged.txt", sourceURL: sourceURL)
        let queued = engine.journal.pendingEntries().first
        XCTAssertEqual(queued?.localFileURL, engine.fileURL(for: "stable-id"))

        try FileManager.default.removeItem(at: sourceURL)
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()
        try await engine.syncPendingWrites(with: adapter)

        let verifyURL = tempCacheDir.appendingPathComponent("verify-staged.txt")
        try await adapter.download(remotePath: "/staged.txt", to: verifyURL, progress: nil)
        XCTAssertEqual(try String(contentsOf: verifyURL, encoding: .utf8), "durable snapshot")
    }

    func testReplayedDeleteMissingRemoteIsIdempotent() async throws {
        let engine = CacheEngine(cacheDirectory: tempCacheDir, journalURL: tempCacheDir.appendingPathComponent("journal-delete.json"))
        engine.enqueue(JournalEntry(action: .delete, itemIdentifier: "delete-id", remotePath: "/already-gone.txt"))

        let adapter = MockFileSystemAdapter()
        try await adapter.connect()
        try await engine.syncPendingWrites(with: adapter)

        XCTAssertEqual(engine.journal.count, 0)
    }

    func testReplayedMoveAfterRemoteSuccessIsIdempotent() async throws {
        let engine = CacheEngine(cacheDirectory: tempCacheDir, journalURL: tempCacheDir.appendingPathComponent("journal-move.json"))
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()
        adapter.seedFile(path: "/before.txt", content: "move once")
        try await adapter.move(from: "/before.txt", to: "/after.txt")

        engine.enqueue(JournalEntry(
            action: .move,
            itemIdentifier: "move-id",
            remotePath: "/before.txt",
            destinationRemotePath: "/after.txt"
        ))
        try await engine.syncPendingWrites(with: adapter)

        XCTAssertEqual(engine.journal.count, 0)
        let verifyURL = tempCacheDir.appendingPathComponent("verify-move.txt")
        try await adapter.download(remotePath: "/after.txt", to: verifyURL, progress: nil)
        XCTAssertEqual(try String(contentsOf: verifyURL, encoding: .utf8), "move once")
    }

    func testQueuedRenameAndUploadPreserveBothOperations() throws {
        let engine = CacheEngine(cacheDirectory: tempCacheDir, journalURL: tempCacheDir.appendingPathComponent("journal-compound.json"))
        let sourceURL = tempCacheDir.appendingPathComponent("compound-source.txt")
        try Data("new content".utf8).write(to: sourceURL)

        engine.enqueue(JournalEntry(
            action: .move,
            itemIdentifier: "compound-id",
            remotePath: "/old.txt",
            destinationRemotePath: "/new.txt"
        ))
        try engine.enqueueUpload(itemIdentifier: "compound-id", remotePath: "/new.txt", sourceURL: sourceURL)

        let pending = engine.journal.pendingEntries()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].action, JournalAction.move)
        XCTAssertEqual(pending[1].action, JournalAction.upload)
    }

    func testReplayedCreateDirectoryAlreadyExistsIsIdempotent() async throws {
        let engine = CacheEngine(cacheDirectory: tempCacheDir, journalURL: tempCacheDir.appendingPathComponent("journal-create.json"))
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()
        try await adapter.createDirectory(path: "/existing")
        engine.enqueue(JournalEntry(action: .createDirectory, itemIdentifier: "directory-id", remotePath: "/existing"))

        try await engine.syncPendingWrites(with: adapter)
        XCTAssertEqual(engine.journal.count, 0)
    }
}
