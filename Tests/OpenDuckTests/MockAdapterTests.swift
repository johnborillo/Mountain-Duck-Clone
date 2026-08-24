import Foundation
import XCTest
@testable import OpenDuckCore

final class MockAdapterTests: XCTestCase {
    func testConnectionLifecycle() async throws {
        let adapter = MockFileSystemAdapter()
        XCTAssertFalse(adapter.isConnected)

        try await adapter.connect()
        XCTAssertTrue(adapter.isConnected)

        await adapter.disconnect()
        XCTAssertFalse(adapter.isConnected)
    }

    func testDirectoryAndFileOperations() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        adapter.seedFile(path: "/logs/app.log", content: "log data")
        adapter.seedFile(path: "/logs/error.log", content: "error data")

        let items = try await adapter.listDirectory(path: "/logs")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0.name }.sorted(), ["app.log", "error.log"])

        // Test stat
        let stat = try await adapter.stat(path: "/logs/app.log")
        XCTAssertEqual(stat.name, "app.log")
        XCTAssertEqual(stat.size, 8)
        XCTAssertFalse(stat.isDirectory)

        // Test create directory
        try await adapter.createDirectory(path: "/logs/archived")
        let updatedItems = try await adapter.listDirectory(path: "/logs")
        XCTAssertEqual(updatedItems.count, 3)

        // Test move
        try await adapter.move(from: "/logs/app.log", to: "/logs/archived/app.log")
        let archivedStat = try await adapter.stat(path: "/logs/archived/app.log")
        XCTAssertEqual(archivedStat.name, "app.log")

        // Test delete
        try await adapter.delete(remotePath: "/logs/error.log")
        let remaining = try await adapter.listDirectory(path: "/logs")
        XCTAssertEqual(remaining.count, 1) // only archived folder left
    }

    func testDisconnectedThrows() async {
        let adapter = MockFileSystemAdapter()
        do {
            _ = try await adapter.listDirectory(path: "/")
            XCTFail("Should throw not connected")
        } catch AdapterError.notConnected {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
