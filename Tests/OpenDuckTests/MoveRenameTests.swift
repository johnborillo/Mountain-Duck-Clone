import Foundation
import OpenDuckCore

final class MoveRenameTests: XCTestCase {
    var tempDir: URL!
    var cacheDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-rename-test-\(UUID().uuidString)")
        cacheDir = tempDir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Test 1: File move issues single remote move (not copy-then-delete)

    func testFileMoveIssuesSingleRemoteMoveNotCopyDelete() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let cacheEngine = CacheEngine(cacheDirectory: cacheDir)
        let volumeManager = VolumeMountManager()

        let context = WatcherContext(
            volumeURL: tempDir,
            remoteRootPath: "/",
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: volumeManager,
            isReadOnly: false
        )

        // Seed file on mock remote
        adapter.seedFile(path: "/old_name.txt", content: "Move test content")

        // Seed record in MetadataDatabase
        let oldLocal = tempDir.appendingPathComponent("old_name.txt").path
        let newLocal = tempDir.appendingPathComponent("new_name.txt").path

        let record = FileRecord(
            volumeName: tempDir.lastPathComponent,
            remotePath: "/old_name.txt",
            localPath: oldLocal,
            fileName: "old_name.txt",
            size: 17,
            isPlaceholder: false,
            state: .materialized
        )
        MetadataDatabase.shared.upsert(record)

        // Create the new local file on disk so handleArrival can stat it
        try "Move test content".write(toFile: newLocal, atomically: true, encoding: .utf8)

        // 1. Departure event: old file disappeared
        context.handleEvent(
            localPath: oldLocal,
            flags: UInt32(kFSEventStreamEventFlagItemRenamed)
        )

        // 2. Arrival event: new file appeared
        context.handleEvent(
            localPath: newLocal,
            flags: UInt32(kFSEventStreamEventFlagItemRenamed)
        )

        // Wait for async task execution
        try await Task.sleep(nanoseconds: 500_000_000)

        // Assert: single remote move issued, no deletes, no uploads
        XCTAssertEqual(adapter.movedPaths.count, 1, "Expected exactly 1 remote move operation")
        XCTAssertEqual(adapter.movedPaths.first?.0, "/old_name.txt")
        XCTAssertEqual(adapter.movedPaths.first?.1, "/new_name.txt")
        XCTAssertTrue(adapter.deletedPaths.isEmpty, "Delete should not have been issued on move")
        XCTAssertTrue(adapter.uploadedPaths.isEmpty, "Upload should not have been issued on move")

        // Assert: database rekeyed to new path
        let newRecord = MetadataDatabase.shared.record(forLocalPath: newLocal)
        XCTAssertNotNil(newRecord)
        XCTAssertEqual(newRecord?.remotePath, "/new_name.txt")
        XCTAssertNil(MetadataDatabase.shared.record(forLocalPath: oldLocal))
    }

    // MARK: - Test 2: Directory move rekeys all descendants

    func testDirectoryMoveRekeysAllDescendants() async throws {
        let volumeName = "T"
        let oldBase = "/Volumes/T/a/sub"
        let newBase = "/Volumes/T/b/sub"

        // Seed directory record and 3 descendant file records
        let dirRec = FileRecord(
            volumeName: volumeName,
            remotePath: "/a/sub",
            localPath: oldBase,
            fileName: "sub",
            size: 0,
            isPlaceholder: false,
            state: .materialized
        )
        MetadataDatabase.shared.upsert(dirRec)

        for i in 1...3 {
            let fileRec = FileRecord(
                volumeName: volumeName,
                remotePath: "/a/sub/\(i).txt",
                localPath: "\(oldBase)/\(i).txt",
                fileName: "\(i).txt",
                size: Int64(i * 100),
                isPlaceholder: true,
                state: .placeholder
            )
            MetadataDatabase.shared.upsert(fileRec)
        }

        // Verify initial state
        let initialRecords = MetadataDatabase.shared.records(underLocalPrefix: oldBase)
        XCTAssertEqual(initialRecords.count, 4)

        // Rekey subtree
        let count = MetadataDatabase.shared.rekeyPathPrefix(
            oldLocalPrefix: oldBase,
            newLocalPrefix: newBase,
            oldRemotePrefix: "/a/sub",
            newRemotePrefix: "/b/sub"
        )

        XCTAssertEqual(count, 4, "Expected 4 records rekeyed")

        // Old prefix should yield zero records
        let oldRecords = MetadataDatabase.shared.records(underLocalPrefix: oldBase)
        XCTAssertEqual(oldRecords.count, 0, "No records should retain the old prefix")

        // New prefix should contain all 4 records rewritten
        let newRecords = MetadataDatabase.shared.records(underLocalPrefix: newBase)
        XCTAssertEqual(newRecords.count, 4)

        let rekeyedDir = MetadataDatabase.shared.record(forLocalPath: newBase)
        XCTAssertNotNil(rekeyedDir)
        XCTAssertEqual(rekeyedDir?.remotePath, "/b/sub")
        XCTAssertEqual(rekeyedDir?.fileName, "sub")

        for i in 1...3 {
            let file = MetadataDatabase.shared.record(forLocalPath: "\(newBase)/\(i).txt")
            XCTAssertNotNil(file)
            XCTAssertEqual(file?.remotePath, "/b/sub/\(i).txt")
            XCTAssertEqual(file?.fileName, "\(i).txt")
        }
    }

    // MARK: - Test 3: Unmatched departure does not delete remote

    func testUnmatchedDepartureDoesNotDeleteRemote() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let cacheEngine = CacheEngine(cacheDirectory: cacheDir)
        let volumeManager = VolumeMountManager()

        let context = WatcherContext(
            volumeURL: tempDir,
            remoteRootPath: "/",
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: volumeManager,
            isReadOnly: false
        )

        adapter.seedFile(path: "/orphan.txt", content: "Orphaned departure")

        let localFile = tempDir.appendingPathComponent("orphan.txt").path
        let record = FileRecord(
            volumeName: tempDir.lastPathComponent,
            remotePath: "/orphan.txt",
            localPath: localFile,
            fileName: "orphan.txt",
            size: 18,
            isPlaceholder: false,
            state: .materialized
        )
        MetadataDatabase.shared.upsert(record)

        // Fire only departure half
        context.handleEvent(
            localPath: localFile,
            flags: UInt32(kFSEventStreamEventFlagItemRenamed)
        )

        // Wait past the correlation window (2.0s + buffer)
        try await Task.sleep(nanoseconds: 2_300_000_000)

        // Assert: remote file was NOT deleted
        XCTAssertTrue(adapter.deletedPaths.isEmpty, "Unmatched departure must never delete remote file")

        // Assert: divergence event was recorded
        let events = MetadataDatabase.shared.allDivergenceEvents()
        XCTAssertTrue(events.contains { $0.path == "/orphan.txt" }, "Divergence event should be recorded for unmatched departure")
    }

    // MARK: - Test 4: Sibling with LIKE metacharacters survives rekey

    func testSiblingWithLikeMetacharactersSurvivesRekey() async throws {
        let volumeName = "T"
        let pathA = "/Volumes/T/a/50%_off"
        let pathB = "/Volumes/T/a/50Xyoff"

        // Seed pathA and pathB subtrees
        MetadataDatabase.shared.upsert(FileRecord(
            volumeName: volumeName,
            remotePath: "/a/50%_off",
            localPath: pathA,
            fileName: "50%_off"
        ))
        MetadataDatabase.shared.upsert(FileRecord(
            volumeName: volumeName,
            remotePath: "/a/50%_off/item.txt",
            localPath: "\(pathA)/item.txt",
            fileName: "item.txt"
        ))

        MetadataDatabase.shared.upsert(FileRecord(
            volumeName: volumeName,
            remotePath: "/a/50Xyoff",
            localPath: pathB,
            fileName: "50Xyoff"
        ))
        MetadataDatabase.shared.upsert(FileRecord(
            volumeName: volumeName,
            remotePath: "/a/50Xyoff/item.txt",
            localPath: "\(pathB)/item.txt",
            fileName: "item.txt"
        ))

        // Rekey pathA only
        MetadataDatabase.shared.rekeyPathPrefix(
            oldLocalPrefix: pathA,
            newLocalPrefix: "/Volumes/T/a/50%_off_new",
            oldRemotePrefix: "/a/50%_off",
            newRemotePrefix: "/a/50%_off_new"
        )

        // Verify pathB records survived unchanged
        let bDir = MetadataDatabase.shared.record(forLocalPath: pathB)
        XCTAssertNotNil(bDir, "Sibling directory must survive when metacharacters are escaped")
        let bFile = MetadataDatabase.shared.record(forLocalPath: "\(pathB)/item.txt")
        XCTAssertNotNil(bFile, "Sibling child must survive when metacharacters are escaped")
    }

    // MARK: - Test 5: Rename then delete in same batch deletes

    func testRenameThenDeleteInSameBatchDeletes() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let cacheEngine = CacheEngine(cacheDirectory: cacheDir)
        let volumeManager = VolumeMountManager()

        let context = WatcherContext(
            volumeURL: tempDir,
            remoteRootPath: "/",
            adapter: adapter,
            cacheEngine: cacheEngine,
            manager: volumeManager,
            isReadOnly: false
        )

        let targetLocal = tempDir.appendingPathComponent("batch_delete.txt").path
        let entry = RemoteFileEntry(name: "batch_delete.txt", path: "/batch_delete.txt", size: 50)
        _ = cacheEngine.registerPlaceholder(for: entry)
        adapter.seedFile(path: "/batch_delete.txt", content: "batch delete content")

        // Flags with both ItemRenamed and ItemRemoved (coalesced by macOS)
        let coalescedFlags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)

        context.handleEvent(
            localPath: targetLocal,
            flags: coalescedFlags
        )

        // Wait for async deletion
        try await Task.sleep(nanoseconds: 500_000_000)

        // Assert: delete path ran instead of rename correlation
        XCTAssertTrue(adapter.deletedPaths.contains("/batch_delete.txt"), "Coalesced rename+remove must trigger delete")
    }
}
