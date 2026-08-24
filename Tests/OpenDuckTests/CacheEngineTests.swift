import Foundation
import Testing
@testable import OpenDuckCore

@Suite final class CacheEngineTests {
    var tempCacheDir: URL

    init() {
        tempCacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-cache-unit-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempCacheDir)
    }

    @Test func placeholderRegistration() {
        let engine = CacheEngine(cacheDirectory: tempCacheDir)
        let entry = RemoteFileEntry(name: "test.txt", path: "/data/test.txt", size: 1024)

        let cached = engine.registerPlaceholder(for: entry)
        #expect(cached.localFileName == "test.txt")
        #expect(cached.state == .placeholder)
        #expect(cached.fileSize == 1024)
    }

    @Test func hydrationAndDirtySync() async throws {
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

        #expect(FileManager.default.fileExists(atPath: localURL.path))
        let initialContent = try String(contentsOf: localURL, encoding: .utf8)
        #expect(initialContent == "{\"version\": 1}")

        // 2. Modify locally & mark dirty
        let modifiedContent = "{\"version\": 2, \"updated\": true}"
        try modifiedContent.write(to: localURL, atomically: true, encoding: .utf8)
        engine.markDirty(itemIdentifier: fileId, newLocalURL: localURL)

        let stats = engine.statistics()
        #expect(stats.dirtyItems == 1)

        // 3. Sync pending writes
        try await engine.syncPendingWrites(with: adapter)

        let postSyncStats = engine.statistics()
        #expect(postSyncStats.dirtyItems == 0)

        // 4. Verify remote has updated data
        let verifyURL = tempCacheDir.appendingPathComponent("verify.json")
        try await adapter.download(remotePath: "/data/config.json", to: verifyURL, progress: nil)
        let remoteContent = try String(contentsOf: verifyURL, encoding: .utf8)
        #expect(remoteContent == modifiedContent)
    }

    @Test func lruEvictionPolicy() {
        let policy = LRUEvictionPolicy(maxCacheSizeBytes: 1000, lowWatermarkPercentage: 0.5)

        let now = Date()
        let oldDate = now.addingTimeInterval(-3600)

        let entry1 = CacheEntry(itemIdentifier: "1", remotePath: "/f1", localFileName: "f1", fileSize: 400, lastAccessedDate: oldDate, isPinned: false, state: .materialized)
        let entry2 = CacheEntry(itemIdentifier: "2", remotePath: "/f2", localFileName: "f2", fileSize: 400, lastAccessedDate: now, isPinned: false, state: .materialized)
        let entry3 = CacheEntry(itemIdentifier: "3", remotePath: "/f3", localFileName: "f3", fileSize: 400, lastAccessedDate: oldDate, isPinned: true, state: .materialized) // Pinned!

        let victims = policy.selectEntriesForEviction(from: [entry1, entry2, entry3])
        // Total = 1200 > 1000. Target = 500. Needs to free 700 bytes.
        // entry3 is pinned, so only entry1 (oldest) and entry2 are candidates.
        #expect(victims.contains { $0.itemIdentifier == "1" })
        #expect(!victims.contains { $0.itemIdentifier == "3" }) // Pinned items must never be evicted
    }

    @Test func purgeUnpinnedProtectsDirtyAndPinnedFiles() async throws {
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

        #expect(FileManager.default.fileExists(atPath: cleanURL.path))
        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))
        #expect(FileManager.default.fileExists(atPath: dirtyURL.path))

        // Execute purge
        try engine.purgeUnpinned()

        // Clean unpinned file MUST be evicted
        #expect(!FileManager.default.fileExists(atPath: cleanURL.path))

        // Pinned file MUST survive
        #expect(FileManager.default.fileExists(atPath: pinnedURL.path))
        let pinnedContent = try String(contentsOf: pinnedURL, encoding: .utf8)
        #expect(pinnedContent == "pinned content")

        // Dirty (unuploaded) file MUST survive intact with dirty edits!
        #expect(FileManager.default.fileExists(atPath: dirtyURL.path))
        let preservedDirtyContent = try String(contentsOf: dirtyURL, encoding: .utf8)
        #expect(preservedDirtyContent == unuploadedEdit)
    }
}
