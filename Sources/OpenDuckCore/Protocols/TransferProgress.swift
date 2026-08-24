import Foundation

/// Direction of a file transfer.
public enum TransferDirection: String, Sendable, Codable {
    case upload
    case download
}

/// Lifecycle stage of a transfer operation.
public enum TransferState: String, Sendable, Codable {
    case queued = "Queued"
    case transferring = "Transferring"
    case staging = "Staging"
    case committing = "Committing"
    case completed = "Completed"
    case failed = "Failed"
}

/// Real-time snapshot of an active or recent file transfer.
public struct TransferProgress: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let localURL: URL
    public let remotePath: String
    public let fileName: String
    public let direction: TransferDirection
    public var state: TransferState
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var progressFraction: Double
    public var estimatedTimeRemaining: TimeInterval?
    public var startTime: Date
    public var lastUpdateTime: Date
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        localURL: URL,
        remotePath: String,
        fileName: String,
        direction: TransferDirection = .upload,
        state: TransferState = .transferring,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0.0,
        progressFraction: Double = 0.0,
        estimatedTimeRemaining: TimeInterval? = nil,
        startTime: Date = Date(),
        lastUpdateTime: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.id = id
        self.localURL = localURL
        self.remotePath = remotePath
        self.fileName = fileName
        self.direction = direction
        self.state = state
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.progressFraction = progressFraction
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.startTime = startTime
        self.lastUpdateTime = lastUpdateTime
        self.errorMessage = errorMessage
    }

    /// Formatted transfer speed (e.g. "3.5 MB/s" or "420 KB/s").
    public var formattedSpeed: String {
        guard state == .transferring || state == .staging else { return "" }
        guard bytesPerSecond > 0 else { return "0 KB/s" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    /// Formatted byte count progress (e.g. "12.4 MB / 45.0 MB").
    public var formattedTransferred: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let transferredStr = formatter.string(fromByteCount: bytesTransferred)
        let totalStr = formatter.string(fromByteCount: totalBytes)
        return "\(transferredStr) / \(totalStr)"
    }

    /// Formatted percentage string (e.g. "27.5%").
    public var percentageString: String {
        let pct = Swift.max(0.0, Swift.min(100.0, progressFraction * 100.0))
        return String(format: "%.1f%%", pct)
    }

    /// Formatted estimated time remaining (e.g. "14s remaining" or "2m 10s remaining").
    public var formattedETA: String {
        guard state == .transferring else { return "" }
        guard let eta = estimatedTimeRemaining, eta.isFinite, eta > 0 else {
            return "Calculating..."
        }
        if eta < 60 {
            return "\(Int(ceil(eta)))s remaining"
        } else {
            let mins = Int(eta) / 60
            let secs = Int(eta) % 60
            return "\(mins)m \(secs)s remaining"
        }
    }
}

/// Utility for tracking bytes transferred, calculating smoothed velocity, and generating transfer snapshots.
public final class TransferTracker: @unchecked Sendable {
    public let id: UUID
    public let localURL: URL
    public let remotePath: String
    public let fileName: String
    public let direction: TransferDirection
    public let totalBytes: Int64
    public let startTime: Date

    private let lock = NSLock()
    private var lastUpdateTime: Date
    private var lastBytesTransferred: Int64 = 0
    private var currentBytesTransferred: Int64 = 0
    private var smoothedSpeed: Double = 0.0
    private var currentState: TransferState = .transferring
    private var errorMessage: String? = nil

    private let onUpdate: (@Sendable (TransferProgress) -> Void)?

    public init(
        id: UUID = UUID(),
        localURL: URL,
        remotePath: String,
        direction: TransferDirection = .upload,
        totalBytes: Int64,
        onUpdate: (@Sendable (TransferProgress) -> Void)? = nil
    ) {
        self.id = id
        self.localURL = localURL
        self.remotePath = remotePath
        self.fileName = localURL.lastPathComponent
        self.direction = direction
        self.totalBytes = totalBytes
        let now = Date()
        self.startTime = now
        self.lastUpdateTime = now
        self.onUpdate = onUpdate

        emitProgress()
    }

    public func update(bytesTransferred: Int64) {
        lock.lock()
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastUpdateTime)

        self.currentBytesTransferred = bytesTransferred
        self.currentState = .transferring

        if timeDelta >= 0.2 { // Sample speed every 200ms
            let bytesDelta = Double(bytesTransferred - lastBytesTransferred)
            let instantSpeed = Swift.max(0.0, bytesDelta / timeDelta)

            // Exponential Moving Average (EMA) with alpha = 0.3 for smooth speed readout
            if smoothedSpeed == 0.0 {
                smoothedSpeed = instantSpeed
            } else {
                smoothedSpeed = (0.3 * instantSpeed) + (0.7 * smoothedSpeed)
            }

            self.lastBytesTransferred = bytesTransferred
            self.lastUpdateTime = now
        }
        lock.unlock()

        emitProgress()
    }

    public func markStaging() {
        lock.lock()
        self.currentState = .staging
        self.currentBytesTransferred = totalBytes
        self.lastUpdateTime = Date()
        lock.unlock()
        emitProgress()
    }

    public func markCommitting() {
        lock.lock()
        self.currentState = .committing
        self.currentBytesTransferred = totalBytes
        self.lastUpdateTime = Date()
        lock.unlock()
        emitProgress()
    }

    public func markCompleted() {
        lock.lock()
        self.currentState = .completed
        self.currentBytesTransferred = totalBytes
        self.lastUpdateTime = Date()
        lock.unlock()
        emitProgress()
    }

    public func markFailed(error: Error) {
        lock.lock()
        self.currentState = .failed
        self.errorMessage = error.localizedDescription
        self.lastUpdateTime = Date()
        lock.unlock()
        emitProgress()
    }

    public func snapshot() -> TransferProgress {
        lock.lock()
        defer { lock.unlock() }

        let fraction = totalBytes > 0 ? Double(currentBytesTransferred) / Double(totalBytes) : 1.0
        let clampedFraction = Swift.max(0.0, Swift.min(1.0, fraction))

        var eta: TimeInterval? = nil
        if currentState == .transferring && smoothedSpeed > 1024 {
            let remainingBytes = Double(Swift.max(0, totalBytes - currentBytesTransferred))
            eta = remainingBytes / smoothedSpeed
        }

        return TransferProgress(
            id: id,
            localURL: localURL,
            remotePath: remotePath,
            fileName: fileName,
            direction: direction,
            state: currentState,
            bytesTransferred: currentBytesTransferred,
            totalBytes: totalBytes,
            bytesPerSecond: smoothedSpeed,
            progressFraction: clampedFraction,
            estimatedTimeRemaining: eta,
            startTime: startTime,
            lastUpdateTime: lastUpdateTime,
            errorMessage: errorMessage
        )
    }

    private func emitProgress() {
        let snap = snapshot()
        onUpdate?(snap)
    }
}
