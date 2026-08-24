import Foundation
import Testing
@testable import OpenDuckCore

@Suite struct MockAdapterTests {
    @Test func connectionLifecycle() async throws {
        let adapter = MockFileSystemAdapter()
        #expect(!adapter.isConnected)

        try await adapter.connect()
        #expect(adapter.isConnected)

        await adapter.disconnect()
        #expect(!adapter.isConnected)
    }

    @Test func directoryAndFileOperations() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        adapter.seedFile(path: "/logs/app.log", content: "log data")
        adapter.seedFile(path: "/logs/error.log", content: "error data")

        let items = try await adapter.listDirectory(path: "/logs")
        #expect(items.count == 2)
        #expect(items.map { $0.name }.sorted() == ["app.log", "error.log"])

        // Test stat
        let stat = try await adapter.stat(path: "/logs/app.log")
        #expect(stat.name == "app.log")
        #expect(stat.size == 8)
        #expect(!stat.isDirectory)

        // Test create directory
        try await adapter.createDirectory(path: "/logs/archived")
        let updatedItems = try await adapter.listDirectory(path: "/logs")
        #expect(updatedItems.count == 3)

        // Test move
        try await adapter.move(from: "/logs/app.log", to: "/logs/archived/app.log")
        let archivedStat = try await adapter.stat(path: "/logs/archived/app.log")
        #expect(archivedStat.name == "app.log")

        // Test delete
        try await adapter.delete(remotePath: "/logs/error.log")
        let remaining = try await adapter.listDirectory(path: "/logs")
        #expect(remaining.count == 1) // only archived folder left
    }

    @Test func disconnectedThrows() async {
        let adapter = MockFileSystemAdapter()
        await #expect(throws: AdapterError.self) {
            _ = try await adapter.listDirectory(path: "/")
        }
    }
}

