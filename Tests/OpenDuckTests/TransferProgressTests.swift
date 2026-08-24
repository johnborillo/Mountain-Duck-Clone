import Foundation
import Testing
@testable import OpenDuckCore

@Suite final class TransferProgressTests {
    var tempDir: URL

    init() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("omd-transfer-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func transferProgressFormatters() {
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

        #expect(progress.percentageString == "30.0%")
        #expect(progress.formattedSpeed.contains("MB/s") || progress.formattedSpeed.contains("M") || progress.formattedSpeed.contains("B/s"))
        #expect(progress.formattedETA == "14s remaining")
        #expect(progress.formattedTransferred.contains("15") && progress.formattedTransferred.contains("50"))

        // Test long ETA (> 1 min)
        progress.estimatedTimeRemaining = 125.0
        #expect(progress.formattedETA == "2m 5s remaining")

        // Test completed state formatters
        progress.state = .completed
        #expect(progress.formattedSpeed == "")
        #expect(progress.formattedETA == "")
    }

    @Test func transferTrackerLifecycleAndSpeedCalculation() async throws {
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

        #expect(collector.count() >= 1)
        #expect(tracker.snapshot().state == .transferring)

        // Simulate streaming chunks
        tracker.update(bytesTransferred: 2 * 1024 * 1024)
        tracker.update(bytesTransferred: 5 * 1024 * 1024)
        tracker.update(bytesTransferred: 10 * 1024 * 1024)

        #expect(tracker.snapshot().bytesTransferred == 10 * 1024 * 1024)
        #expect(tracker.snapshot().progressFraction == 1.0)

        // Mark completed
        tracker.markCompleted()
        #expect(tracker.snapshot().state == .completed)
        #expect(collector.last()?.state == .completed)
    }

    @Test func mockAdapterChunkProgress() async throws {
        let adapter = MockFileSystemAdapter()
        try await adapter.connect()

        let dummyURL = tempDir.appendingPathComponent("mock_upload.txt")
        let testString = "Hello OpenDuck Transfer Metrics!"
        let testData = Data(testString.utf8)
        try testData.write(to: dummyURL)

        let progress = Progress(totalUnitCount: Int64(testData.count))
        try await adapter.upload(from: dummyURL, to: "/mock_upload.txt", progress: progress)

        #expect(progress.completedUnitCount == Int64(testData.count))
        #expect(progress.fractionCompleted == 1.0)

        let downloadURL = tempDir.appendingPathComponent("mock_download.txt")
        let dlProgress = Progress(totalUnitCount: Int64(testData.count))
        try await adapter.download(remotePath: "/mock_upload.txt", to: downloadURL, progress: dlProgress)

        #expect(dlProgress.completedUnitCount == Int64(testData.count))
        #expect(FileManager.default.fileExists(atPath: downloadURL.path))
    }
}
