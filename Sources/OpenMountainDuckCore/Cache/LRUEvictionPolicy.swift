import Foundation

/// Strategy for pruning unpinned cached files when local storage boundaries are reached.
public struct LRUEvictionPolicy: Sendable {
    public let maxCacheSizeBytes: Int64
    public let lowWatermarkPercentage: Double // Evict down to e.g. 80% of max capacity

    public init(
        maxCacheSizeBytes: Int64 = 5 * 1024 * 1024 * 1024, // 5 GB default
        lowWatermarkPercentage: Double = 0.80
    ) {
        self.maxCacheSizeBytes = maxCacheSizeBytes
        self.lowWatermarkPercentage = lowWatermarkPercentage
    }

    /// Determines which cache entries to evict based on size constraints and LRU access times.
    public func selectEntriesForEviction(from entries: [CacheEntry]) -> [CacheEntry] {
        let materializedUnpinned = entries.filter {
            ($0.state == .materialized || $0.state == .evicted) && !$0.isPinned
        }

        let totalUsedBytes: Int64 = entries.reduce(0) { sum, entry in
            (entry.state == .materialized || entry.state == .dirty) ? sum + entry.fileSize : sum
        }

        guard totalUsedBytes > maxCacheSizeBytes else {
            return []
        }

        let targetSizeBytes = Int64(Double(maxCacheSizeBytes) * lowWatermarkPercentage)
        var bytesToFree = totalUsedBytes - targetSizeBytes

        // Sort by least-recently-accessed first
        let sortedCandidates = materializedUnpinned.sorted {
            $0.lastAccessedDate < $1.lastAccessedDate
        }

        var victims: [CacheEntry] = []
        for candidate in sortedCandidates {
            if bytesToFree <= 0 { break }
            victims.append(candidate)
            bytesToFree -= candidate.fileSize
        }

        return victims
    }
}
