import Foundation
import OpenDuckCore

final class TransferProgressTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-transfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testTransferProgressFormatters() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample_video.mov")
        var progress = TransferProgress(
            localURL: dummyURL,
            remotePath: "/media/sample_video.mov",
            fileName: "sample_video.mov",
            direction: .upload,
            state: .transferring,
            bytesTransferred: 15_000_000, // 15 MB
            totalBytes: 50_000_000,       // 50 MB
            bytesPerSecond: 2_500_000,    // 2.5 MB/s
            progressFraction: 0.3,
            estimatedTimeRemaining: 14.0
        )

        XCTAssertEqual(progress.percentageString, "30.0%")
        XCTAssertTrue(progress.formattedSpeed.contains("MB/s") || progress.formattedSpeed.contains("M") || progress.formattedSpeed.contains("B/s"))
        XCTAssertEqual(progress.formattedETA, "14s remaining")
        XCTAssertTrue(progress.formattedTransferred.contains("15") && progress.formattedTransferred.contains("50"))

        // Test long ETA (> 1 min)
        progress.estimatedTimeRemaining = 125.0
        XCTAssertEqual(progress.formattedETA, "2m 5s remaining")

        // Test completed state formatters
        progress.state = .completed
        XCTAssertEqual(progress.formattedSpeed, "")
        XCTAssertEqual(progress.formattedETA, "")
    }

    func testTransferTrackerLifecycleAndSpeedCalculation() async throws {
        let dummyURL = tempDir.appendingPathComponent("test_data.bin")
        let totalSize: Int64 = 10 * 1024 * 1024 // 10 MB
        let dummyData = Data(repeating: 0xAB, count: Int(totalSize))
        try dummyData.write(to: dummyURL)

        final class ProgressCollector: @unchecked Sendable {
            var updates: [TransferProgress] = []
            private let lock = NSLock()
            func add(_ p: TransferProgress) {
                lock.lock()
                updates.append(p)
                lock.unlock()
            }
            func count() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return updates.count
            }
            func last() -> TransferProgress? {
                lock.lock()
                defer { lock.unlock() }
                return updates.last
            }
        }

        let collector = ProgressCollector()
        let tracker = TransferTracker(
            localURL: dummyURL,
            remotePath: "/remote/test_data.bin",
            direction: .upload,
            totalBytes: totalSize,
            onUpdate: { p in
                collector.add(p)
            }
        )

        XCTAssertGreaterThanOrEqual(collector.count(), 1)
        XCTAssertEqual(tracker.snapshot().state, .transferring)

        // Simulate streaming chunks
        tracker.update(bytesTransferred: 2 * 1024 * 1024)
        tracker.update(bytesTransferred: 5 * 1024 * 1024)
        tracker.update(bytesTransferred: 10 * 1024 * 1024)

        XCTAssertEqual(tracker.snapshot().bytesTransferred, 10 * 1024 * 1024)
        XCTAssertEqual(tracker.snapshot().progressFraction, 1.0)

        // Mark completed
        tracker.markCompleted()
        XCTAssertEqual(tracker.snapshot().state, .completed)
        XCTAssertEqual(collector.last()?.state, .completed)
    }

    func testMockAdapterChunkProgress() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let dummyURL = tempDir.appendingPathComponent("mock_upload.txt")
        let testString = "Hello OpenDuck Transfer Metrics!"
        let testData = Data(testString.utf8)
        try testData.write(to: dummyURL)

        let progress = Progress(totalUnitCount: Int64(testData.count))
        try await adapter.upload(from: dummyURL, to: "/mock_upload.txt", progress: progress)

        XCTAssertEqual(progress.completedUnitCount, Int64(testData.count))
        XCTAssertEqual(progress.fractionCompleted, 1.0)

        let downloadURL = tempDir.appendingPathComponent("mock_download.txt")
        let dlProgress = Progress(totalUnitCount: Int64(testData.count))
        try await adapter.download(remotePath: "/mock_upload.txt", to: downloadURL, progress: dlProgress)

        XCTAssertEqual(dlProgress.completedUnitCount, Int64(testData.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadURL.path))
    }
}
