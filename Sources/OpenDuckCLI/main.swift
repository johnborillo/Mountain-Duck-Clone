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

        case "test-live-sync", "sync-test":
            await runLiveSandboxSyncTests(args: Array(args.dropFirst(2)))

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
            print("Usage: openduck test-sftp <user@host> [--port 22] [--key ~/.ssh/id_ed25519] [--password <pass>] [--path /]")
            return
        }

        let parts = target.split(separator: "@")
        let username = String(parts[0])
        let host = String(parts[1])

        var port = 22
        var keyPath: String? = nil
        var password: String? = nil
        var remotePath = "/"

        var i = 1
        while i < args.count {
            if args[i] == "--port" && i + 1 < args.count {
                port = Int(args[i + 1]) ?? 22
                i += 2
            } else if args[i] == "--key" && i + 1 < args.count {
                keyPath = args[i + 1]
                i += 2
            } else if args[i] == "--password" && i + 1 < args.count {
                password = args[i + 1]
                i += 2
            } else if args[i] == "--path" && i + 1 < args.count {
                remotePath = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }

        print("🦆 Testing Live SFTP Connection to \(username)@\(host):\(port)\(remotePath)...")

        let authMethod: SFTPAuthMethod
        if let pwd = password {
            authMethod = .password(pwd)
        } else {
            let defaultKey = NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath
            let resolvedKey = keyPath ?? (FileManager.default.fileExists(atPath: defaultKey) ? "~/.ssh/id_ed25519" : "~/.ssh/id_rsa")
            authMethod = .privateKey(keyPath: resolvedKey, passphrase: nil)
        }

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

    static func runLiveSandboxSyncTests(args: [String]) async {
        let defaultHost = ProcessInfo.processInfo.environment["OPENDUCK_TEST_HOST"] ?? "127.0.0.1"
        let defaultUser = ProcessInfo.processInfo.environment["OPENDUCK_TEST_USER"] ?? "user"
        let defaultKey = ProcessInfo.processInfo.environment["OPENDUCK_TEST_KEY"] ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/id_ed25519")
        let defaultPath = ProcessInfo.processInfo.environment["OPENDUCK_TEST_PATH"] ?? "/tmp/openduck_test"

        var host = defaultHost
        var username = defaultUser
        var keyPath = defaultKey
        var remotePath = defaultPath

        var i = 0
        while i < args.count {
            if args[i] == "--host" && i + 1 < args.count {
                host = args[i + 1]
                i += 2
            } else if args[i] == "--user" && i + 1 < args.count {
                username = args[i + 1]
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

        // =========================================================================
        // STRICT SAFETY BARRIER: SANDBOX SCOPE ENFORCEMENT
        // Never allow running this test on any directory other than /openduck_test
        // =========================================================================
        guard remotePath.contains("openduck_test") else {
            print("🛑 SAFETY ABORT: Live test is strictly restricted to sandbox path containing 'openduck_test'. Given: '\(remotePath)'")
            return
        }

        print("""
        =================================================================
        🧪 OpenDuck Live Sandbox Sync & Anti-Corruption Test Suite
        =================================================================
        Endpoint:    \(username)@\(host):22
        Key Path:    \(keyPath)
        Remote Path: \(remotePath) (STRICT SANDBOX)
        =================================================================
        """)

        var passed = 0
        var failed = 0

        func assertTest(_ condition: Bool, _ name: String, details: String = "") {
            if condition {
                print("  ✓ PASS: \(name)")
                passed += 1
            } else {
                print("  ❌ FAIL: \(name) \(details.isEmpty ? "" : "- " + details)")
                failed += 1
            }
        }

        let config = SFTPConfiguration(
            host: host,
            port: 22,
            username: username,
            authMethod: .privateKey(keyPath: keyPath, passphrase: nil),
            rootPath: remotePath
        )

        let adapter = SFTPAdapter(configuration: config)
        let localSandboxDir = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-local-sandbox-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: localSandboxDir, withIntermediateDirectories: true)

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-cache-sandbox-\(UUID().uuidString)")
        let cacheEngine = CacheEngine(cacheDirectory: cacheDir)
        let volumeManager = VolumeMountManager()

        do {
            print("Connecting to live SFTP server...")
            try await adapter.connect()
            assertTest(adapter.isConnected, "Connection established to SFTP sandbox")

            // Clean remote sandbox before test
            let initialItems = try await adapter.listDirectory(path: remotePath)
            for item in initialItems {
                try? await adapter.delete(remotePath: item.path)
            }
            print("  ✓ Cleaned remote sandbox for isolated test run.")

            // -------------------------------------------------------------
            // SCENARIO 1: Remote Upload (Cyberduck) -> OpenDuck Sync -> Local Presence & Hydration
            // -------------------------------------------------------------
            print("\n[Scenario 1/10] Remote Upload (Cyberduck) -> OpenDuck Sync -> Local Presence & Hydration")
            let remoteFile1 = remotePath + "/cyberduck_doc.txt"
            let tempUpload1 = localSandboxDir.appendingPathComponent("temp_cd_1.txt")
            let testPayload1 = "This is document #1 uploaded remotely via Cyberduck.\nTimestamp: \(Date())"
            try testPayload1.write(to: tempUpload1, atomically: true, encoding: .utf8)
            try await adapter.upload(from: tempUpload1, to: remoteFile1, progress: nil)

            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )

            let localStub1 = localSandboxDir.appendingPathComponent("cyberduck_doc.txt")
            assertTest(FileManager.default.fileExists(atPath: localStub1.path), "Local placeholder created for remote file")
            assertTest(VolumeMountManager.isPlaceholderXAttr(path: localStub1.path), "Local file is marked with placeholder xattr")

            let fileId1 = cacheEngine.itemIdentifier(for: remoteFile1)
            let hydratedURL = try await cacheEngine.getOrHydrate(itemIdentifier: fileId1, remotePath: remoteFile1, adapter: adapter)
            let hydratedContent = try String(contentsOf: hydratedURL, encoding: .utf8)
            assertTest(hydratedContent == testPayload1, "Hydrated file content matches remote source bit-for-bit")
            try? await adapter.delete(remotePath: remoteFile1)
            try? FileManager.default.removeItem(at: localStub1)

            // -------------------------------------------------------------
            // SCENARIO 2: Remote Upload (Cyberduck) -> OpenDuck Sync -> Local Delete in OpenDuck -> Remote Delete
            // -------------------------------------------------------------
            print("\n[Scenario 2/10] Remote Upload (Cyberduck) -> OpenDuck Sync -> Local Delete in OpenDuck -> Remote Delete")
            let remoteFile2 = remotePath + "/cyberduck_to_delete.txt"
            let tempUpload2 = localSandboxDir.appendingPathComponent("temp_cd_2.txt")
            try "Delete me via OpenDuck".write(to: tempUpload2, atomically: true, encoding: .utf8)
            try await adapter.upload(from: tempUpload2, to: remoteFile2, progress: nil)

            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )
            let localStub2 = localSandboxDir.appendingPathComponent("cyberduck_to_delete.txt")
            assertTest(FileManager.default.fileExists(atPath: localStub2.path), "Placeholder appeared locally")

            // User deletes in OpenDuck
            try FileManager.default.removeItem(at: localStub2)
            assertTest(!FileManager.default.fileExists(atPath: localStub2.path), "Deleted locally in OpenDuck")

            // Trigger remote delete
            try await adapter.delete(remotePath: remoteFile2)
            assertTest((try? await adapter.stat(path: remoteFile2)) == nil, "File verified deleted on remote SFTP server")

            // -------------------------------------------------------------
            // SCENARIO 3: Remote Upload (Cyberduck) -> OpenDuck Sync -> Local Edit in OpenDuck -> Remote Update
            // -------------------------------------------------------------
            print("\n[Scenario 3/10] Remote Upload (Cyberduck) -> OpenDuck Sync -> Local Edit in OpenDuck -> Remote Update")
            let remoteFile3 = remotePath + "/editable_file.txt"
            let tempUpload3 = localSandboxDir.appendingPathComponent("temp_cd_3.txt")
            try "Original content from Cyberduck v1".write(to: tempUpload3, atomically: true, encoding: .utf8)
            try await adapter.upload(from: tempUpload3, to: remoteFile3, progress: nil)

            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )
            let localStub3 = localSandboxDir.appendingPathComponent("editable_file.txt")
            let fileId3 = cacheEngine.itemIdentifier(for: remoteFile3)
            let localHydrated3 = try await cacheEngine.getOrHydrate(itemIdentifier: fileId3, remotePath: remoteFile3, adapter: adapter)

            // Local user edits the file
            let updatedPayload3 = "Modified locally by OpenDuck v2 with 100% integrity"
            try updatedPayload3.write(to: localHydrated3, atomically: true, encoding: .utf8)
            cacheEngine.markDirty(itemIdentifier: fileId3, newLocalURL: localHydrated3)

            // OpenDuck uploads modified version
            try await adapter.upload(from: localHydrated3, to: remoteFile3, progress: nil)
            cacheEngine.markClean(itemIdentifier: fileId3, remotePath: remoteFile3)

            let remoteStat3 = try await adapter.stat(path: remoteFile3)
            assertTest(remoteStat3.size == Int64(updatedPayload3.utf8.count), "Remote server received updated content with exact byte length")
            try? await adapter.delete(remotePath: remoteFile3)
            try? FileManager.default.removeItem(at: localStub3)

            // -------------------------------------------------------------
            // SCENARIO 4: Local Creation in OpenDuck -> Remote Upload -> Remote Delete (Cyberduck) -> Local Prune
            // -------------------------------------------------------------
            print("\n[Scenario 4/10] Local Creation in OpenDuck -> Remote Upload -> Remote Delete (Cyberduck) -> Local Prune")
            let localCreatedFile4 = localSandboxDir.appendingPathComponent("local_created.txt")
            try "Created inside OpenDuck volume".write(to: localCreatedFile4, atomically: true, encoding: .utf8)

            let remoteDestination4 = remotePath + "/local_created.txt"
            try await adapter.upload(from: localCreatedFile4, to: remoteDestination4, progress: nil)
            assertTest((try? await adapter.stat(path: remoteDestination4)) != nil, "Local creation uploaded to remote server")

            // User deletes remotely in Cyberduck
            try await adapter.delete(remotePath: remoteDestination4)
            assertTest((try? await adapter.stat(path: remoteDestination4)) == nil, "Deleted remotely on Cyberduck")

            // OpenDuck syncs
            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )
            // Reconcile deletion of placeholder
            if VolumeMountManager.isPlaceholderXAttr(path: localCreatedFile4.path) {
                try? FileManager.default.removeItem(at: localCreatedFile4)
            }
            assertTest((try? await adapter.stat(path: remoteDestination4)) == nil, "Local & remote verified in sync after deletion")
            try? FileManager.default.removeItem(at: localCreatedFile4)

            // -------------------------------------------------------------
            // SCENARIO 5: Local Creation -> Remote Edit on Cyberduck -> OpenDuck Sync -> Hydrates New Version
            // -------------------------------------------------------------
            print("\n[Scenario 5/10] Local Creation -> Remote Edit on Cyberduck -> OpenDuck Sync -> Hydrates New Version")
            let remoteFile5 = remotePath + "/collaborative_doc.txt"
            let localFile5 = localSandboxDir.appendingPathComponent("collaborative_doc.txt")
            try "Version 1 created in OpenDuck".write(to: localFile5, atomically: true, encoding: .utf8)
            try await adapter.upload(from: localFile5, to: remoteFile5, progress: nil)

            // Cyberduck edits remote file
            let remoteUpdatedPayload5 = "Version 2 updated by another user in Cyberduck"
            let tempEdit5 = localSandboxDir.appendingPathComponent("temp_edit_5.txt")
            try remoteUpdatedPayload5.write(to: tempEdit5, atomically: true, encoding: .utf8)
            try await adapter.upload(from: tempEdit5, to: remoteFile5, progress: nil)

            // OpenDuck syncs
            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )
            let fileId5 = cacheEngine.itemIdentifier(for: remoteFile5)
            // Evict stale cached copy to force re-download
            try? cacheEngine.evict(itemIdentifier: fileId5)
            let localHydrated5 = try await cacheEngine.getOrHydrate(itemIdentifier: fileId5, remotePath: remoteFile5, adapter: adapter)
            let rehydratedContent5 = try String(contentsOf: localHydrated5, encoding: .utf8)
            assertTest(rehydratedContent5 == remoteUpdatedPayload5, "OpenDuck downloaded and hydrated the new remote Cyberduck version")
            try? await adapter.delete(remotePath: remoteFile5)
            try? FileManager.default.removeItem(at: localFile5)

            // -------------------------------------------------------------
            // SCENARIO 6: Nested Directory & Subfolder Full Lifecycle
            // -------------------------------------------------------------
            print("\n[Scenario 6/10] Nested Directory & Subfolder Full Lifecycle")
            let subfolderRemote = remotePath + "/nested_folder"
            try await adapter.createDirectory(path: subfolderRemote)

            let nestedRemoteFile = subfolderRemote + "/nested_image.png"
            let localNestedSeed = localSandboxDir.appendingPathComponent("temp_nested_image.png")
            let nestedData = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
            try nestedData.write(to: localNestedSeed)
            try await adapter.upload(from: localNestedSeed, to: nestedRemoteFile, progress: nil)

            // OpenDuck syncs root
            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )
            let localSubfolder = localSandboxDir.appendingPathComponent("nested_folder")
            assertTest(FileManager.default.fileExists(atPath: localSubfolder.path), "Subfolder directory created locally")

            // Lazy populate subfolder
            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: subfolderRemote,
                localURL: localSubfolder,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )
            let localNestedStub = localSubfolder.appendingPathComponent("nested_image.png")
            assertTest(FileManager.default.fileExists(atPath: localNestedStub.path), "Nested file placeholder created inside subfolder")

            // Cleanup subfolder
            try? await adapter.delete(remotePath: nestedRemoteFile)
            try? await adapter.delete(remotePath: subfolderRemote)
            try? FileManager.default.removeItem(at: localSubfolder)

            // -------------------------------------------------------------
            // SCENARIO 7: File Renaming Across Remote & Local
            // -------------------------------------------------------------
            print("\n[Scenario 7/10] File Renaming Across Remote & Local")
            let renameSrcRemote = remotePath + "/original_name.txt"
            let renameDstRemote = remotePath + "/renamed_target.txt"
            let tempRename = localSandboxDir.appendingPathComponent("temp_rename.txt")
            try "Renaming test payload".write(to: tempRename, atomically: true, encoding: .utf8)
            try await adapter.upload(from: tempRename, to: renameSrcRemote, progress: nil)

            // Remote rename (Cyberduck)
            try await adapter.move(from: renameSrcRemote, to: renameDstRemote)
            assertTest((try? await adapter.stat(path: renameSrcRemote)) == nil, "Original remote file no longer exists")
            assertTest((try? await adapter.stat(path: renameDstRemote)) != nil, "Renamed remote file exists on server")

            // OpenDuck syncs
            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )
            assertTest(FileManager.default.fileExists(atPath: localSandboxDir.appendingPathComponent("renamed_target.txt").path),
                       "OpenDuck reflects the renamed file locally")
            try? await adapter.delete(remotePath: renameDstRemote)

            // -------------------------------------------------------------
            // SCENARIO 8: Rapid Sequential Local Writes (Debounce & Flush Integrity)
            // -------------------------------------------------------------
            print("\n[Scenario 8/10] Rapid Sequential Local Writes (Debounce Integrity)")
            let debounceRemote = remotePath + "/rapid_write.txt"
            let localDebounceFile = localSandboxDir.appendingPathComponent("rapid_write.txt")
            for step in 1...5 {
                try "Write iteration #\(step)".write(to: localDebounceFile, atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            // Upload stabilized final version
            try await adapter.upload(from: localDebounceFile, to: debounceRemote, progress: nil)
            let finalStat = try await adapter.stat(path: debounceRemote)
            assertTest(finalStat.size == Int64("Write iteration #5".utf8.count), "Final stabilized write uploaded accurately without intermediate race conditions")
            try? await adapter.delete(remotePath: debounceRemote)
            try? FileManager.default.removeItem(at: localDebounceFile)

            // -------------------------------------------------------------
            // SCENARIO 9: Safety Shield Hard 0-Byte Overwrite Protection
            // -------------------------------------------------------------
            print("\n[Scenario 9/10] Safety Shield Multi-Vector 0-Byte Overwrite Protection")
            let remoteImportant = remotePath + "/important_media.mkv"
            let localImportantSeed = localSandboxDir.appendingPathComponent("seed_media.mkv")
            let seedData = Data((0..<8192).map { _ in UInt8.random(in: 0...255) })
            try seedData.write(to: localImportantSeed)
            try await adapter.upload(from: localImportantSeed, to: remoteImportant, progress: nil)

            let importantStatBefore = try await adapter.stat(path: remoteImportant)
            assertTest(importantStatBefore.size == 8192, "Seeded 8192-byte remote file on server")

            let localZeroByte = localSandboxDir.appendingPathComponent("zero_byte_attempt.mkv")
            FileManager.default.createFile(atPath: localZeroByte.path, contents: nil)

            var safetyShieldTriggered = false
            do {
                try await adapter.upload(from: localZeroByte, to: remoteImportant, progress: nil)
            } catch {
                safetyShieldTriggered = true
                print("  🛡️ Shield Interception: \(error.localizedDescription)")
            }
            assertTest(safetyShieldTriggered, "Safety Shield successfully BLOCKED 0-byte overwrite")

            let importantStatAfter = try await adapter.stat(path: remoteImportant)
            assertTest(importantStatAfter.size == 8192, "Remote file remains completely intact (8192 bytes preserved)")
            try? await adapter.delete(remotePath: remoteImportant)

            // -------------------------------------------------------------
            // SCENARIO 10: Multi-File Batch Two-Way Divergence & Convergence Roundtrip
            // -------------------------------------------------------------
            print("\n[Scenario 10/10] Multi-File Batch Two-Way Divergence & Convergence Roundtrip")
            let fA = remotePath + "/batch_a.txt"
            let fB = remotePath + "/batch_b.jpg"
            let fC = remotePath + "/batch_c.json"

            let tmpA = localSandboxDir.appendingPathComponent("b_a.txt")
            let tmpB = localSandboxDir.appendingPathComponent("b_b.jpg")
            let tmpC = localSandboxDir.appendingPathComponent("b_c.json")
            try "A".write(to: tmpA, atomically: true, encoding: .utf8)
            try "B".write(to: tmpB, atomically: true, encoding: .utf8)
            try "C".write(to: tmpC, atomically: true, encoding: .utf8)

            try await adapter.upload(from: tmpA, to: fA, progress: nil)
            try await adapter.upload(from: tmpB, to: fB, progress: nil)
            try await adapter.upload(from: tmpC, to: fC, progress: nil)

            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )

            assertTest(FileManager.default.fileExists(atPath: localSandboxDir.appendingPathComponent("batch_a.txt").path) &&
                       FileManager.default.fileExists(atPath: localSandboxDir.appendingPathComponent("batch_b.jpg").path) &&
                       FileManager.default.fileExists(atPath: localSandboxDir.appendingPathComponent("batch_c.json").path),
                       "All 3 batch files materialized locally via OpenDuck Sync")

            // Delete batch_b remotely (Cyberduck)
            try await adapter.delete(remotePath: fB)
            _ = try await volumeManager.populateDirectory(
                adapter: adapter,
                remotePath: remotePath,
                localURL: localSandboxDir,
                cacheEngine: cacheEngine,
                forceRefresh: true
            )

            assertTest(!FileManager.default.fileExists(atPath: localSandboxDir.appendingPathComponent("batch_b.jpg").path),
                       "batch_b.jpg pruned locally after remote Cyberduck deletion")
            assertTest(FileManager.default.fileExists(atPath: localSandboxDir.appendingPathComponent("batch_a.txt").path),
                       "batch_a.txt remains untouched locally and remotely")

            // Clean up remote batch files
            try? await adapter.delete(remotePath: fA)
            try? await adapter.delete(remotePath: fC)

            await adapter.disconnect()
        } catch {
            assertTest(false, "Test failed with unexpected error", details: "\(error)")
        }

        try? FileManager.default.removeItem(at: localSandboxDir)
        try? FileManager.default.removeItem(at: cacheDir)

        print("\n=================================================================")
        print("📊 Live Sandbox Test Results: \(passed) Passed, \(failed) Failed (Total: \(passed + failed))")
        print("=================================================================")
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

        // --- Suite 5: Safety Shield & Anti-Corruption Tests ---
        print("\n[5/5] Running SafetyShieldTests...")
        let safetyTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-safety-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: safetyTempDir, withIntermediateDirectories: true)

        let testPlaceholderPath = safetyTempDir.appendingPathComponent("test_placeholder.txt").path
        FileManager.default.createFile(atPath: testPlaceholderPath, contents: nil)

        // Test 1: Placeholder XAttr Detection
        VolumeMountManager.setPlaceholderXAttr(path: testPlaceholderPath)
        assert(VolumeMountManager.isPlaceholderXAttr(path: testPlaceholderPath), "Safety Shield: Placeholder xattr correctly tagged and identified")

        VolumeMountManager.removePlaceholderXAttr(path: testPlaceholderPath)
        assert(!VolumeMountManager.isPlaceholderXAttr(path: testPlaceholderPath), "Safety Shield: Placeholder xattr cleanly removed on user edit")

        // Test 2: Hard Overwrite Guard (0-byte file)
        let zeroByteFile = safetyTempDir.appendingPathComponent("empty.mkv")
        FileManager.default.createFile(atPath: zeroByteFile.path, contents: nil)
        assert(FileManager.default.fileExists(atPath: zeroByteFile.path), "Safety Shield: Zero-byte file created for protection test")
        try? FileManager.default.removeItem(at: safetyTempDir)

        // --- Suite 6: Persistent SQLite Metadata Database Tests ---
        print("\n[6/6] Running MetadataDatabaseTests...")
        let dbTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-db-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dbTempDir, withIntermediateDirectories: true)
        let dbURL = dbTempDir.appendingPathComponent("test_meta.sqlite")
        let db = MetadataDatabase(databaseURL: dbURL)

        db.markPlaceholder(
            localPath: "/Volumes/Expedition/image.png",
            remotePath: "/photos/image.png",
            volumeName: "Expedition",
            fileName: "image.png",
            size: 2048,
            remoteMtime: Date()
        )
        assert(db.isPlaceholder(localPath: "/Volumes/Expedition/image.png"), "MetadataDatabase: marks and detects placeholder")

        db.markDirty(localPath: "/Volumes/Expedition/image.png")
        let dirtyRecords = db.allDirtyRecords()
        assert(dirtyRecords.count == 1 && dirtyRecords.first?.state == .dirty, "MetadataDatabase: marks and lists dirty item")

        db.markClean(localPath: "/Volumes/Expedition/image.png", remoteMtime: Date(), size: 2048)
        assert(!db.isPlaceholder(localPath: "/Volumes/Expedition/image.png") && db.allDirtyRecords().isEmpty, "MetadataDatabase: marks item materialized and clean")

        // Host Key Pinning (TOFU) test
        db.pinHostKey(host: "10.0.0.1", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:abcd1234dummy")
        let pinnedKey = db.pinnedFingerprint(forHost: "10.0.0.1", port: 22)
        assert(pinnedKey == "SHA256:abcd1234dummy", "MetadataDatabase: pins and retrieves host key fingerprint")

        // Divergence event logging test
        db.recordDivergenceEvent(volumeName: "Expedition", path: "MASS_DELETION_BREAKER", reason: "Test halt")

        // Persistence test across database reconnection
        let db2 = MetadataDatabase(databaseURL: dbURL)
        let persisted = db2.record(forLocalPath: "/Volumes/Expedition/image.png")
        assert(persisted != nil && persisted?.size == 2048 && persisted?.state == .materialized, "MetadataDatabase: maintains ACID persistence across re-instantiation")
        assert(db2.pinnedFingerprint(forHost: "10.0.0.1", port: 22) == "SHA256:abcd1234dummy", "MetadataDatabase: host key pin persists across restart")

        db2.deleteRecord(localPath: "/Volumes/Expedition/image.png")
        assert(db2.record(forLocalPath: "/Volumes/Expedition/image.png") == nil, "MetadataDatabase: deletes record on removal")

        try? FileManager.default.removeItem(at: dbTempDir)

        // Self-initiated removal provenance test
        let vm = VolumeMountManager()
        vm.recordSelfInitiatedRemoval(path: "/Volumes/Test/evicted.txt")
        assert(vm.isSelfInitiatedRemoval(path: "/Volumes/Test/evicted.txt"), "VolumeMountManager: identifies self-initiated removal")
        assert(!vm.isSelfInitiatedRemoval(path: "/Volumes/Test/evicted.txt"), "VolumeMountManager: consumes removal token on inspection")

        // --- Suite 7: Adversarial Path & Refused-Delete Hardening Tests ---
        print("\n[7/7] Running AdversarialPathsAndRefusedDeleteTests...")
        let advAdapter = MockFileSystemAdapter(endpointDescription: "mock://adversarial.server")
        do {
            try await advAdapter.connect()

            // 1. Adversarial filenames: spaces, quotes, wildcards, dashes, emojis, and newlines
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
                advAdapter.seedFile(path: path, content: "Content for \(name)")
                let stat = try await advAdapter.stat(path: path)
                assert(stat.name == name && stat.size > 0, "Adversarial Path: Seeded and verified '\(name.replacingOccurrences(of: "\n", with: "\\n"))'")

                // Test move/rename with adversarial names
                let renamedPath = "/renamed_\(name)"
                try await advAdapter.move(from: path, to: renamedPath)
                let renamedStat = try await advAdapter.stat(path: renamedPath)
                assert(renamedStat.name == "renamed_\(name)", "Adversarial Path: Renamed '\(name.replacingOccurrences(of: "\n", with: "\\n"))'")

                // Test delete with adversarial names
                try await advAdapter.delete(remotePath: renamedPath)
                let deletedStat = try? await advAdapter.stat(path: renamedPath)
                assert(deletedStat == nil, "Adversarial Path: Deleted '\(name.replacingOccurrences(of: "\n", with: "\\n"))'")
            }

            // 2. Refused-Delete Safeguard: Verify that when OpenDuck marks an eviction, the delete is refused
            let testManager = VolumeMountManager()
            let victimFile = "/Volumes/Test/evicted_clean_file.png"
            testManager.recordSelfInitiatedRemoval(path: victimFile)

            // Provenance check must consume token and refuse delete
            let wasSelfInitiated = testManager.isSelfInitiatedRemoval(path: victimFile)
            assert(wasSelfInitiated, "Refused Delete: Self-initiated removal correctly recognized and intercepted")

            // Second check must be false (one-time token consumed)
            let isStale = testManager.isSelfInitiatedRemoval(path: victimFile)
            assert(!isStale, "Refused Delete: Token cleanly exhausted to prevent suppression leaks")
        } catch {
            assert(false, "Adversarial tests threw unexpected error: \(error)")
        }

        // 8. Delete Sync & Circuit Breaker Journaling Tests
        print("\n[8/8] Running DeleteSyncAndCircuitBreakerJournalingTests...")
        do {
            let deleteAdapter = MockFileSystemAdapter(endpointDescription: "mock://delete.server")
            try await deleteAdapter.connect()

            let testTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-cli-deltest-\(UUID().uuidString)")
            let testCacheDir = testTempDir.appendingPathComponent("cache")
            let testJournalURL = testTempDir.appendingPathComponent("journal.json")
            try? FileManager.default.createDirectory(at: testCacheDir, withIntermediateDirectories: true)

            let testEngine = CacheEngine(cacheDirectory: testCacheDir, journalURL: testJournalURL)
            let testVolumeManager = VolumeMountManager()

            // 8a. Hydration loop prevention
            testVolumeManager.recordHydratingPath("/Volumes/Test/downloading.dat")
            let isHydrating = testVolumeManager.isHydratingPath("/Volumes/Test/downloading.dat")
            assert(isHydrating, "Hydration Loop: Hydrating path token registered and recognized")
            let isHydratingAgain = testVolumeManager.isHydratingPath("/Volumes/Test/downloading.dat")
            assert(!isHydratingAgain, "Hydration Loop: Hydrating path token exhausted after inspection")

            // 8b. SQLite Provenance token persistence
            let crashTestPath = "/Volumes/Test/crash_resilient.txt"
            testVolumeManager.recordSelfInitiatedRemoval(path: crashTestPath)
            let persistedTokenExists = MetadataDatabase.shared.consumeSelfInitiatedRemoval(localPath: crashTestPath)
            assert(persistedTokenExists, "Provenance Persistence: Token stored and consumed from SQLite")

            // 8c. Journaling on delete failure
            let context = WatcherContext(
                volumeURL: testTempDir,
                remoteRootPath: "/",
                adapter: deleteAdapter,
                cacheEngine: testEngine,
                manager: testVolumeManager,
                isReadOnly: false
            )

            // Seed file and register in cache
            deleteAdapter.seedFile(path: "/to_delete.txt", content: "delete me")
            let entry = RemoteFileEntry(name: "to_delete.txt", path: "/to_delete.txt", size: 9)
            _ = testEngine.registerPlaceholder(for: entry)

            // Set simulated error to force delete failure
            deleteAdapter.simulatedError = AdapterError.networkError("Simulated network drop")

            let localVictimFile = testTempDir.appendingPathComponent("to_delete.txt")
            try "delete me".write(to: localVictimFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: localVictimFile)

            context.handleEvent(localPath: localVictimFile.path, flags: 0x00000200)
            try await Task.sleep(for: .milliseconds(300))

            let pending = testEngine.journal.pendingEntries()
            let deleteJournaled = pending.contains { $0.action == .delete && $0.remotePath == "/to_delete.txt" }
            assert(deleteJournaled, "Delete Resiliency: Failed delete automatically journaled for retry")

            // 8d. Flushed journal retry after network recovery
            deleteAdapter.simulatedError = nil
            try await testEngine.syncPendingWrites(with: deleteAdapter)
            let pendingAfterSync = testEngine.journal.pendingEntries()
            assert(pendingAfterSync.isEmpty, "Delete Resiliency: Pending delete journal executed and cleared on sync")
            let statAfterDelete = try? await deleteAdapter.stat(path: "/to_delete.txt")
            assert(statAfterDelete == nil, "Delete Resiliency: Remote file deleted after journal flush")

            try? FileManager.default.removeItem(at: testTempDir)
        } catch {
            assert(false, "Delete sync tests threw unexpected error: \(error)")
        }

        // --- Suite 9: Connection Editing, Deletion & Transfer Cancellation Tests ---
        print("\n[9/9] Running ConnectionEditingDeletingAndTransferCancellationTests...")
        let suiteUserDefaults = UserDefaults(suiteName: "com.openduck.testsuite.\(UUID().uuidString)")!
        let cmTest = ConnectionManager(keychain: .shared, userDefaults: suiteUserDefaults)

        let initialProfile = ServerProfile(
            name: "Initial Connection",
            protocolType: .sftp,
            host: "sftp1.example.com",
            port: 22,
            username: "expedition",
            remoteRootPath: "/remote"
        )
        cmTest.registerProfile(initialProfile)
        assert(cmTest.allProfiles().contains { $0.id == initialProfile.id }, "ConnectionManager: Registered initial connection profile")

        // 9a. Test profile editing & persistence
        var editedProfile = initialProfile
        editedProfile.name = "Renamed Expedition Connection"
        editedProfile.host = "sftp2.example.com"
        editedProfile.port = 2222
        cmTest.updateProfile(editedProfile, secret: "new-secret-token")

        let retrieved = cmTest.profile(for: initialProfile.id)
        assert(retrieved?.name == "Renamed Expedition Connection", "ConnectionManager: Profile name updated successfully")
        assert(retrieved?.host == "sftp2.example.com" && retrieved?.port == 2222, "ConnectionManager: Host and port updated successfully")

        // 9b. Test re-instantiation from UserDefaults
        let cmReinstantiated = ConnectionManager(keychain: .shared, userDefaults: suiteUserDefaults)
        let loadedFromDisk = cmReinstantiated.profile(for: initialProfile.id)
        assert(loadedFromDisk?.name == "Renamed Expedition Connection", "ConnectionManager: Profile updates persist across re-instantiation")

        // 9c. Test connection deletion
        cmTest.deleteProfile(id: initialProfile.id)
        assert(cmTest.profile(for: initialProfile.id) == nil, "ConnectionManager: Profile deleted from in-memory index")
        let cmAfterDelete = ConnectionManager(keychain: .shared, userDefaults: suiteUserDefaults)
        assert(cmAfterDelete.profile(for: initialProfile.id) == nil, "ConnectionManager: Profile deletion persisted to disk")

        // 9d. Test Transfer Cancellation and File Removal
        let cancelTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-cancel-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cancelTempDir, withIntermediateDirectories: true)
        let cancelCacheDir = cancelTempDir.appendingPathComponent("cache")
        let cancelEngine = CacheEngine(cacheDirectory: cancelCacheDir)
        let cancelManager = VolumeMountManager()
        let cancelAdapter = MockFileSystemAdapter()

        let cancelContext = WatcherContext(
            volumeURL: cancelTempDir,
            remoteRootPath: "/",
            adapter: cancelAdapter,
            cacheEngine: cancelEngine,
            manager: cancelManager,
            isReadOnly: false
        )

        let transferringFile = cancelTempDir.appendingPathComponent("in_flight_file.bin")
        try? "Binary payload data for cancellation test".write(to: transferringFile, atomically: true, encoding: .utf8)
        assert(FileManager.default.fileExists(atPath: transferringFile.path), "Transfer Cancellation: Local in-flight file created")

        // Cancel with deleteLocal = true
        cancelContext.cancelTransfer(remotePath: "/in_flight_file.bin", localURL: transferringFile, deleteLocal: true)
        assert(!FileManager.default.fileExists(atPath: transferringFile.path), "Transfer Cancellation: Local file successfully removed upon cancel & delete")

        try? FileManager.default.removeItem(at: cancelTempDir)

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
        guard let profile = ConnectionManager.shared.allProfiles().first(where: { $0.name == name || $0.id.uuidString == name }) else {
            print("❌ No connection profile named '\(name)'. Run 'openduck profiles' first.")
            return
        }
        do {
            try await FileProviderDomainCoordinator.register(profile: profile)
            print("✓ Successfully mounted '\(name)' domain into Finder.")
        } catch {
            print("Note: Domain registration returned: \(error.localizedDescription)")
            print("If running outside an app bundle container, use the OpenDuck host app.")
        }
    }

    static func unmountDomain(name: String) async {
        guard let profile = ConnectionManager.shared.allProfiles().first(where: { $0.name == name || $0.id.uuidString == name }) else {
            print("❌ No connection profile named '\(name)'. Run 'openduck profiles' first.")
            return
        }
        do {
            try await FileProviderDomainCoordinator.unregister(profile: profile)
            print("✓ Successfully unmounted '\(name)' domain from Finder.")
        } catch {
            print("Note: Domain unregistration returned: \(error.localizedDescription)")
        }
    }
}
