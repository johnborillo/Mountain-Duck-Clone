import Foundation
import OpenDuckCore

final class AdversarialPathsTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-adv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testAdversarialFilenamesAndNewlineHandling() async throws {
        let adapter = MockFileSystemAdapter(endpointDescription: "mock://adversarial.endpoint")
        try await adapter.connect()

        let adversarialNames = [
            "my document.txt",
            "say\"hello.txt",
            "*",
            "important-*.csv",
            "-rf.txt",
            "résumé_🎨.pdf",
            "line1\nline2.txt"
        ]

        for name in adversarialNames {
            let path = "/\(name)"
            let payload = "Payload for \(name)"
            adapter.seedFile(path: path, content: payload)

            // Stat verification
            let stat = try await adapter.stat(path: path)
            XCTAssertEqual(stat.name, name)
            XCTAssertEqual(stat.size, Int64(payload.utf8.count))

            // Download verification
            let downloadLocal = tempDir.appendingPathComponent(UUID().uuidString)
            try await adapter.download(remotePath: path, to: downloadLocal, progress: nil)
            let readData = try String(contentsOf: downloadLocal, encoding: .utf8)
            XCTAssertEqual(readData, payload)

            // Move / Rename verification
            let renamedPath = "/renamed_\(name)"
            try await adapter.move(from: path, to: renamedPath)
            let renamedStat = try await adapter.stat(path: renamedPath)
            XCTAssertEqual(renamedStat.name, "renamed_\(name)")

            // Delete verification
            try await adapter.delete(remotePath: renamedPath)
            do {
                _ = try await adapter.stat(path: renamedPath)
                XCTFail("Expected AdapterError to be thrown")
            } catch is AdapterError {
                // Expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSelfInitiatedRemovalTokenLifecycle() {
        let vm = VolumeMountManager()
        let path = "/Volumes/Test/evicted_file.png"

        vm.recordSelfInitiatedRemoval(path: path)
        // First check consumes the token
        XCTAssertTrue(vm.isSelfInitiatedRemoval(path: path))
        // Second check must be false (token exhausted)
        XCTAssertFalse(vm.isSelfInitiatedRemoval(path: path))
    }
}
