import Foundation
import OpenDuckCore
import FileProvider
import UniformTypeIdentifiers

@main
struct OpenDuckCLI {
    static func main() async {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            printUsage()
            return
        }

        let command = args[1]

        switch command {
        case "test", "test-all":
            await runFullTestSuite()

        case "test-mock":
            await runMockSimulation()

        case "test-sftp", "sftp-test":
            await runLiveSFTPTest(args: Array(args.dropFirst(2)))

        case "cache-stats":
            await showCacheStats()

        case "profiles":
            showProfiles()

        case "mount":
            if args.count > 2 {
                await mountDomain(name: args[2])
            } else {
                print("Error: Missing domain name. Usage: openduck mount <name>")
            }

        case "unmount":
            if args.count > 2 {
                await unmountDomain(name: args[2])
            } else {
                print("Error: Missing domain name. Usage: openduck unmount <name>")
            }

        case "help", "--help", "-h":
            printUsage()

        default:
            print("Unknown command: \(command)")
            printUsage()
        }
    }

    static func printUsage() {
        print("""
        ===========================================================
        🦆 OpenDuck CLI (openduck) - Native macOS Cloud Mounter
        ===========================================================

        Commands:
          test-sftp <user@host> [--port 22] [--key ~/.ssh/id_rsa] [--path /]
                          Test a live SFTP connection, list tree & test sync
          test            Execute the full automated test suite
          test-mock       Execute a simulated remote filesystem session
          cache-stats     Display local cache usage and LRU metrics
          profiles        List all configured server profiles
          mount <name>    Register an NSFileProviderDomain in Finder
          unmount <name>  Deregister an NSFileProviderDomain from Finder
          help            Show this help dialog
        """)
    }

    static func runLiveSFTPTest(args: [String]) async {
        guard let target = args.first, target.contains("@") else {
            print("Usage: omd test-sftp <user@host> [--port 22] [--key ~/.ssh/id_ed25519] [--path /]")
            return
        }

        let parts = target.split(separator: "@")
        let username = String(parts[0])
        let host = String(parts[1])

        var port = 22
        var keyPath: String? = nil
        var remotePath = "/"

        var i = 1
        while i < args.count {
            if args[i] == "--port" && i + 1 < args.count {
                port = Int(args[i + 1]) ?? 22
                i += 2
            } else if args[i] == "--key" && i + 1 < args.count {
                keyPath = args[i + 1]
                i += 2
            } else if args[i] == "--path" && i + 1 < args.count {
                remotePath = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }

        print("🦆 Testing Live SFTP Connection to \(username)@\(host):\(port)\(remotePath)...")

        let authMethod: SFTPAuthMethod = (keyPath != nil) ? .privateKey(keyPath: keyPath!, passphrase: nil) : .agent
        let config = SFTPConfiguration(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            rootPath: remotePath
        )

        let adapter = SFTPAdapter(configuration: config)

        do {
            print("  [1/4] Establishing SSH connection handshake...")
            try await adapter.connect()
            print("  ✓ Connected successfully!")

            print("  [2/4] Listing directory contents of '\(remotePath)'...")
            let items = try await adapter.listDirectory(path: remotePath)
            print("  ✓ Found \(items.count) item(s):")
            for item in items.prefix(15) {
                print("      - [\(item.itemType.rawValue)] \(item.name) (\(item.size) bytes)")
            }
            if items.count > 15 {
                print("      ... and \(items.count - 15) more items")
            }

            print("  [3/4] Testing cache engine on-demand hydration...")
            let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-live-cache-\(UUID().uuidString)")
            let cacheEngine = CacheEngine(cacheDirectory: cacheDir)

            if let firstFile = items.first(where: { !$0.isDirectory }) {
                let fileId = cacheEngine.itemIdentifier(for: firstFile.path)
                let localURL = try await cacheEngine.getOrHydrate(itemIdentifier: fileId, remotePath: firstFile.path, adapter: adapter)
                print("  ✓ Successfully hydrated remote file '\(firstFile.name)' to: \(localURL.path)")
            } else {
                print("  ℹ️ No files found to hydrate (directory contains only folders).")
            }

            print("  [4/4] Disconnecting cleanly...")
            await adapter.disconnect()
            print("🎉 Live SFTP Test completed with 100% SUCCESS!")
        } catch {
            print("❌ Live SFTP connection failed: \(error.localizedDescription)")
        }
    }

    static func showProfiles() {
        let manager = ConnectionManager.shared
        let profiles = manager.allProfiles()
        if profiles.isEmpty {
            print("No profiles configured yet.")
            return
        }
        print("Configured Profiles (\(profiles.count)):")
        for p in profiles {
            print(" - [\(p.protocolType.rawValue)] \(p.name) (\(p.username)@\(p.host):\(p.port)\(p.remoteRootPath))")
        }
    }

    static func showCacheStats() async {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-cli-cache")
        let engine = CacheEngine(cacheDirectory: cacheDir)
        let stats = engine.statistics()
        print("""
        Local Cache Statistics:
          Total Items Indexed:    \(stats.totalItems)
          Materialized Files:     \(stats.materializedItems)
          Pinned Items:           \(stats.pinnedItems)
          Pending Dirty Writes:   \(stats.dirtyItems)
          Disk Footprint:         \(stats.totalSizeBytes) bytes
          Max Capacity Limit:     \(stats.maxCapacityBytes) bytes
        """)
    }

    static func runFullTestSuite() async {
        print("🧪 Executing OpenDuck Complete Test Suite...\n")
        var passed = 0
        var failed = 0

        func assert(_ condition: Bool, _ testName: String) {
            if condition {
                print("  ✓ PASS: \(testName)")
                passed += 1
            } else {
                print("  ❌ FAIL: \(testName)")
                failed += 1
            }
        }

        // --- Suite 1: Mock Adapter Tests ---
        print("[1/4] Running MockAdapterTests...")
        let adapter = MockFileSystemAdapter()
        assert(!adapter.isConnected, "MockAdapter starts disconnected")

        do {
            try await adapter.connect()
            assert(adapter.isConnected, "MockAdapter connects successfully")

            adapter.seedFile(path: "/logs/app.log", content: "log data")
            adapter.seedFile(path: "/logs/error.log", content: "error data")

            let items = try await adapter.listDirectory(path: "/logs")
            assert(items.count == 2, "MockAdapter lists exact child entries")
            assert(items.map { $0.name }.sorted() == ["app.log", "error.log"], "MockAdapter entry names match")

            let stat = try await adapter.stat(path: "/logs/app.log")
            assert(stat.size == 8 && !stat.isDirectory, "MockAdapter stat reports accurate file size")

            try await adapter.createDirectory(path: "/logs/archived")
            try await adapter.move(from: "/logs/app.log", to: "/logs/archived/app.log")
            let movedStat = try await adapter.stat(path: "/logs/archived/app.log")
            assert(movedStat.name == "app.log", "MockAdapter move succeeds")

            try await adapter.delete(remotePath: "/logs/error.log")
            let remaining = try await adapter.listDirectory(path: "/logs")
            assert(remaining.count == 1, "MockAdapter delete succeeds")

            await adapter.disconnect()
            assert(!adapter.isConnected, "MockAdapter disconnects cleanly")
        } catch {
            assert(false, "MockAdapter threw unexpected error: \(error)")
        }

        // --- Suite 2: Cache Engine & LRU Tests ---
        print("\n[2/4] Running CacheEngineTests...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-test-\(UUID().uuidString)")
        let cacheEngine = CacheEngine(cacheDirectory: tempDir)

        let placeholder = cacheEngine.registerPlaceholder(for: RemoteFileEntry(name: "doc.txt", path: "/doc.txt", size: 500))
        assert(placeholder.state == .placeholder && placeholder.fileSize == 500, "CacheEngine placeholder registration")

        let testAdapter = MockFileSystemAdapter()
        do {
            try await testAdapter.connect()
            testAdapter.seedFile(path: "/doc.txt", content: "Initial cache test data")

            let fileId = cacheEngine.itemIdentifier(for: "/doc.txt")
            let hydratedURL = try await cacheEngine.getOrHydrate(itemIdentifier: fileId, remotePath: "/doc.txt", adapter: testAdapter)
            assert(FileManager.default.fileExists(atPath: hydratedURL.path), "CacheEngine on-demand hydration materialized file")

            let modified = "Updated cache content for write-back"
            try modified.write(to: hydratedURL, atomically: true, encoding: .utf8)
            cacheEngine.markDirty(itemIdentifier: fileId, newLocalURL: hydratedURL)
            assert(cacheEngine.statistics().dirtyItems == 1, "CacheEngine marks dirty file accurately")

            try await cacheEngine.syncPendingWrites(with: testAdapter)
            assert(cacheEngine.statistics().dirtyItems == 0, "CacheEngine synchronizes dirty journal to backend")

            // LRU Eviction verification
            let lru = LRUEvictionPolicy(maxCacheSizeBytes: 1000, lowWatermarkPercentage: 0.5)
            let e1 = CacheEntry(itemIdentifier: "1", remotePath: "/f1", localFileName: "f1", fileSize: 400, lastAccessedDate: Date().addingTimeInterval(-100), isPinned: false, state: .materialized)
            let e2 = CacheEntry(itemIdentifier: "2", remotePath: "/f2", localFileName: "f2", fileSize: 400, lastAccessedDate: Date(), isPinned: false, state: .materialized)
            let e3 = CacheEntry(itemIdentifier: "3", remotePath: "/f3", localFileName: "f3", fileSize: 400, lastAccessedDate: Date().addingTimeInterval(-100), isPinned: true, state: .materialized)
            let victims = lru.selectEntriesForEviction(from: [e1, e2, e3])
            assert(victims.contains { $0.itemIdentifier == "1" } && !victims.contains { $0.itemIdentifier == "3" }, "LRUEvictionPolicy evicts oldest unpinned files and protects pinned items")
        } catch {
            assert(false, "CacheEngine threw unexpected error: \(error)")
        }
        try? FileManager.default.removeItem(at: tempDir)

        // --- Suite 3: File Provider Item Tests ---
        print("\n[3/4] Running FileProviderItemTests...")
        let remoteEntry = RemoteFileEntry(name: "archive.pdf", path: "/books/archive.pdf", itemType: .file, size: 4096)
        let fpItem = FileProviderItem(from: remoteEntry, parentIdentifier: .rootContainer, isDownloaded: true)
        assert(fpItem.filename == "archive.pdf", "FileProviderItem filename mapping")
        assert(fpItem.contentType == .pdf, "FileProviderItem UTI type identification")
        assert(fpItem.isDownloaded, "FileProviderItem download state tracking")
        assert(fpItem.capabilities.contains(.allowsReading) && fpItem.capabilities.contains(.allowsWriting), "FileProviderItem read/write capabilities")

        // --- Suite 4: Connection Manager Tests ---
        print("\n[4/4] Running ConnectionManagerTests...")
        let cm = ConnectionManager()
        let profile = ServerProfile(name: "Mock Expedition Server", protocolType: .mock)
        cm.registerProfile(profile)
        assert(cm.allProfiles().contains { $0.id == profile.id }, "ConnectionManager profile registration")

        do {
            let active = try await cm.connect(to: profile.id)
            assert(active.isConnected, "ConnectionManager establishes connection via profile")
            assert(cm.activeAdapter(for: profile.id) != nil, "ConnectionManager tracks active adapter instance")

            await cm.disconnect(from: profile.id)
            assert(cm.activeAdapter(for: profile.id) == nil, "ConnectionManager purges inactive connection from pool")
        } catch {
            assert(false, "ConnectionManager threw unexpected error: \(error)")
        }

        print("\n===========================================================")
        print("📊 Test Summary: \(passed) Passed, \(failed) Failed (Total: \(passed + failed))")
        print("===========================================================")
    }

    static func runMockSimulation() async {
        print("🦆 Starting OpenDuck End-to-End Simulation...")

        let mockAdapter = MockFileSystemAdapter(endpointDescription: "mock://expedition33.server")
        do {
            try await mockAdapter.connect()
            print("  ✓ Connected to simulated endpoint: \(mockAdapter.endpointDescription)")

            mockAdapter.seedFile(path: "/documents/manifest.txt", content: "Expedition 33 System Log - All Systems Operational")
            mockAdapter.seedFile(path: "/documents/coordinates.json", content: "{\"x\": 33.4, \"y\": 108.9}")
            mockAdapter.seedFile(path: "/images/capture.png", content: "PNG_DATA_PLACEHOLDER")
            print("  ✓ Seeded simulated remote directory hierarchy")

            let rootItems = try await mockAdapter.listDirectory(path: "/")
            print("  ✓ Root directory listing (\(rootItems.count) items):")
            for item in rootItems {
                print("      - [\(item.itemType.rawValue)] \(item.name)")
            }

            let docItems = try await mockAdapter.listDirectory(path: "/documents")
            print("  ✓ /documents listing (\(docItems.count) items):")
            for item in docItems {
                print("      - [\(item.itemType.rawValue)] \(item.name) (\(item.size) bytes)")
            }

            let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-test-cache-\(UUID().uuidString)")
            let cacheEngine = CacheEngine(cacheDirectory: cacheDir)
            let fileId = cacheEngine.itemIdentifier(for: "/documents/manifest.txt")

            print("  ✓ Hydrating /documents/manifest.txt on demand...")
            let localURL = try await cacheEngine.getOrHydrate(
                itemIdentifier: fileId,
                remotePath: "/documents/manifest.txt",
                adapter: mockAdapter
            )
            let content = try String(contentsOf: localURL, encoding: .utf8)
            print("      Local cached content: \"\(content)\"")

            let newContent = content + "\n[Update: Rune Decoded Successfully]"
            try newContent.write(to: localURL, atomically: true, encoding: .utf8)
            cacheEngine.markDirty(itemIdentifier: fileId, newLocalURL: localURL)
            print("  ✓ Modified file locally; marked dirty in CacheEngine")

            print("  ✓ Synchronizing dirty writes to remote adapter...")
            try await cacheEngine.syncPendingWrites(with: mockAdapter)

            let updatedURL = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-verify-\(UUID().uuidString)")
            try await mockAdapter.download(remotePath: "/documents/manifest.txt", to: updatedURL, progress: nil)
            let verifiedContent = try String(contentsOf: updatedURL, encoding: .utf8)
            print("  ✓ Verified remote server received update:")
            print("--------------------------------------------------")
            print(verifiedContent)
            print("--------------------------------------------------")
            print("🎉 Simulation completed with 100% fidelity.")
        } catch {
            print("❌ Simulation failed with error: \(error)")
        }
    }

    static func mountDomain(name: String) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(name),
            displayName: name
        )
        do {
            try await NSFileProviderManager.add(domain)
            print("✓ Successfully mounted '\(name)' domain into Finder.")
        } catch {
            print("Note: Domain registration returned: \(error.localizedDescription)")
            print("If running outside an app bundle container, use the OpenDuck host app.")
        }
    }

    static func unmountDomain(name: String) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(name),
            displayName: name
        )
        do {
            try await NSFileProviderManager.remove(domain)
            print("✓ Successfully unmounted '\(name)' domain from Finder.")
        } catch {
            print("Note: Domain unregistration returned: \(error.localizedDescription)")
        }
    }
}
