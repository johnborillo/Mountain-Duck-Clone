import Foundation
import OpenDuckCore

final class TransferPipelineTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-pipeline-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testAsyncTransferQueueConcurrencyLimiting() async {
        let queue = AsyncTransferQueue(maxConcurrent: 3)
        final class Counter: @unchecked Sendable {
            var active = 0
            var maxObserved = 0
            private let lock = NSLock()

            func increment() {
                lock.lock()
                active += 1
                if active > maxObserved { maxObserved = active }
                lock.unlock()
            }

            func decrement() {
                lock.lock()
                active -= 1
                lock.unlock()
            }
        }

        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await queue.acquire()
                    counter.increment()
                    try? await Task.sleep(nanoseconds: 20_000_000) // 20ms work
                    counter.decrement()
                    await queue.release()
                }
            }
            await group.waitForAll()
        }

        XCTAssertLessThanOrEqual(counter.maxObserved, 3, "Queue must strictly bound concurrency to maxConcurrent")
    }

    func testStreamingDownloadAndUploadIntegrity() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        // Seed 4 MB binary payload
        let payloadSize = 4 * 1024 * 1024
        var sampleBytes = [UInt8](repeating: 0, count: payloadSize)
        for i in 0..<payloadSize {
            sampleBytes[i] = UInt8(i % 256)
        }
        let originalData = Data(sampleBytes)

        let uploadSource = tempDir.appendingPathComponent("large_source.bin")
        try originalData.write(to: uploadSource)

        try await adapter.createDirectory(path: "/remote")

        let uploadProgress = Progress(totalUnitCount: Int64(payloadSize))
        try await adapter.upload(from: uploadSource, to: "/remote/large.bin", progress: uploadProgress)

        XCTAssertEqual(uploadProgress.completedUnitCount, Int64(payloadSize))

        // Download back to a different local file
        let downloadDestination = tempDir.appendingPathComponent("large_download.bin")
        let downloadProgress = Progress(totalUnitCount: Int64(payloadSize))
        try await adapter.download(remotePath: "/remote/large.bin", to: downloadDestination, progress: downloadProgress)

        XCTAssertEqual(downloadProgress.completedUnitCount, Int64(payloadSize))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadDestination.path))

        let downloadedData = try Data(contentsOf: downloadDestination)
        XCTAssertEqual(downloadedData.count, payloadSize)
        XCTAssertEqual(downloadedData, originalData, "Downloaded payload must match uploaded binary data bit-for-bit")
    }
}
