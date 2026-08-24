import Foundation
import Testing
@testable import OpenDuckCore

@Suite final class AdversarialPathsTests {
    var tempDir: URL

    init() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-adv-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func adversarialFilenamesAndNewlineHandling() async throws {
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
            #expect(stat.name == name)
            #expect(stat.size == Int64(payload.utf8.count))

            // Download verification
            let downloadLocal = tempDir.appendingPathComponent(UUID().uuidString)
            try await adapter.download(remotePath: path, to: downloadLocal, progress: nil)
            let readData = try String(contentsOf: downloadLocal, encoding: .utf8)
            #expect(readData == payload)

            // Move / Rename verification
            let renamedPath = "/renamed_\(name)"
            try await adapter.move(from: path, to: renamedPath)
            let renamedStat = try await adapter.stat(path: renamedPath)
            #expect(renamedStat.name == "renamed_\(name)")

            // Delete verification
            try await adapter.delete(remotePath: renamedPath)
            await #expect(throws: AdapterError.self) {
                _ = try await adapter.stat(path: renamedPath)
            }
        }
    }

    @Test func selfInitiatedRemovalTokenLifecycle() {
        let vm = VolumeMountManager()
        let path = "/Volumes/Test/evicted_file.png"

        vm.recordSelfInitiatedRemoval(path: path)
        // First check consumes the token
        #expect(vm.isSelfInitiatedRemoval(path: path))
        // Second check must be false (token exhausted)
        #expect(!vm.isSelfInitiatedRemoval(path: path))
    }
}
