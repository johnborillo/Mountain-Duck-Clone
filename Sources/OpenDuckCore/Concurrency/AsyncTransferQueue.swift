import Foundation

/// A concurrency-bounding primitive that limits the number of simultaneous
/// file transfer operations across any upload/download entry point.
///
/// Uses a FIFO continuation queue: callers that exceed `maxConcurrent` are
/// suspended in order and resumed one-at-a-time as earlier transfers complete.
public actor AsyncTransferQueue {
    private let maxConcurrent: Int
    private var inFlight: Int = 0
    private var waitQueue: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    /// Acquire a transfer permit. Suspends if the maximum concurrency limit is reached.
    public func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitQueue.append(continuation)
        }
    }

    /// Release a transfer permit. Resumes the next waiting caller, if any.
    public func release() {
        if !waitQueue.isEmpty {
            let next = waitQueue.removeFirst()
            next.resume()
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }
}

