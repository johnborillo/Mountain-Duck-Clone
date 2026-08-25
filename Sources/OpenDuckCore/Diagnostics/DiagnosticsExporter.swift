import Foundation

/// A redacted, support-friendly snapshot of local OpenDuck state.
///
/// The report intentionally excludes passwords, private-key contents, and cached
/// file data. Local source paths are reduced to their final component so a user
/// can attach the report without disclosing their home-directory layout.
public enum DiagnosticsExporter {
    private struct Report: Codable {
        struct Profile: Codable {
            let id: UUID
            let name: String
            let protocolType: String
            let host: String
            let port: Int
            let username: String
            let authType: String
            let remoteRootPath: String
            let autoConnect: Bool
            let isReadOnly: Bool
            let lastConnectedAt: Date?
        }

        struct Operation: Codable {
            let id: UUID
            let action: String
            let itemIdentifier: String
            let remotePath: String
            let destinationRemotePath: String?
            let localFileName: String?
            let timestamp: Date
            let retryCount: Int
        }

        struct Conflict: Codable {
            let id: String
            let domainIdentifier: String
            let itemIdentifier: String
            let remotePath: String
            let localVersion: String
            let remoteVersion: String
            let createdAt: Date
            let resolution: String
        }

        let generatedAt: Date
        let appVersion: String
        let osVersion: String
        let profiles: [Profile]
        let cache: CacheStatisticsSnapshot
        let pendingOperations: [Operation]
        let conflicts: [Conflict]
    }

    private struct CacheStatisticsSnapshot: Codable {
        let totalItems: Int
        let materializedItems: Int
        let pinnedItems: Int
        let dirtyItems: Int
        let totalSizeBytes: Int64
        let maxCapacityBytes: Int64

        init(_ stats: CacheStatistics) {
            totalItems = stats.totalItems
            materializedItems = stats.materializedItems
            pinnedItems = stats.pinnedItems
            dirtyItems = stats.dirtyItems
            totalSizeBytes = stats.totalSizeBytes
            maxCapacityBytes = stats.maxCapacityBytes
        }
    }

    public static func makeReport(
        profiles: [ServerProfile],
        cacheStats: CacheStatistics,
        pendingOperations: [JournalEntry],
        conflicts: [DomainConflict],
        generatedAt: Date = Date()
    ) throws -> Data {
        let report = Report(
            generatedAt: generatedAt,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            profiles: profiles.map {
                Report.Profile(
                    id: $0.id,
                    name: $0.name,
                    protocolType: $0.protocolType.rawValue,
                    host: $0.host,
                    port: $0.port,
                    username: $0.username,
                    authType: $0.authType.rawValue,
                    remoteRootPath: $0.remoteRootPath,
                    autoConnect: $0.autoConnect,
                    isReadOnly: $0.isReadOnly,
                    lastConnectedAt: $0.lastConnectedAt
                )
            },
            cache: CacheStatisticsSnapshot(cacheStats),
            pendingOperations: pendingOperations.map {
                Report.Operation(
                    id: $0.id,
                    action: $0.action.rawValue,
                    itemIdentifier: $0.itemIdentifier,
                    remotePath: $0.remotePath,
                    destinationRemotePath: $0.destinationRemotePath,
                    localFileName: $0.localFileURL?.lastPathComponent,
                    timestamp: $0.timestamp,
                    retryCount: $0.retryCount
                )
            },
            conflicts: conflicts.map {
                Report.Conflict(
                    id: $0.id,
                    domainIdentifier: $0.domainIdentifier,
                    itemIdentifier: $0.itemIdentifier,
                    remotePath: $0.remotePath,
                    localVersion: $0.localVersion,
                    remoteVersion: $0.remoteVersion,
                    createdAt: $0.createdAt,
                    resolution: $0.resolution.rawValue
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    @discardableResult
    public static func writeReport(
        profiles: [ServerProfile],
        cacheStats: CacheStatistics,
        pendingOperations: [JournalEntry],
        conflicts: [DomainConflict],
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let data = try makeReport(
            profiles: profiles,
            cacheStats: cacheStats,
            pendingOperations: pendingOperations,
            conflicts: conflicts
        )
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("OpenDuck-Diagnostics-\(timestamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
