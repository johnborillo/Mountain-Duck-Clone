import Foundation
import SQLite3

/// Synchronization lifecycle state of a virtual filesystem item.
public enum ItemSyncState: String, Sendable, Codable {
    case placeholder
    case hydrating
    case materialized
    case dirty
    case uploading
}

/// Persistent metadata record for a file or directory on a virtual volume.
public struct FileRecord: Sendable, Codable {
    public let id: String
    public let volumeName: String
    public let remotePath: String
    public let localPath: String
    public let fileName: String
    public var size: Int64
    public var isPlaceholder: Bool
    public var state: ItemSyncState
    public var etag: String?
    public var remoteMtime: Date
    public var localMtime: Date
    public var lastSynced: Date
    public var isPinned: Bool

    public init(
        id: String = UUID().uuidString,
        volumeName: String,
        remotePath: String,
        localPath: String,
        fileName: String,
        size: Int64 = 0,
        isPlaceholder: Bool = true,
        state: ItemSyncState = .placeholder,
        etag: String? = nil,
        remoteMtime: Date = Date(),
        localMtime: Date = Date(),
        lastSynced: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.volumeName = volumeName
        self.remotePath = remotePath
        self.localPath = localPath
        self.fileName = fileName
        self.size = size
        self.isPlaceholder = isPlaceholder
        self.state = state
        self.etag = etag
        self.remoteMtime = remoteMtime
        self.localMtime = localMtime
        self.lastSynced = lastSynced
        self.isPinned = isPinned
    }
}

/// Thread-safe SQLite-backed metadata storage engine providing ACID persistence across crashes and restarts.
public final class MetadataDatabase: @unchecked Sendable {
    public static let shared = MetadataDatabase()

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let databaseURL: URL

    public init(databaseURL: URL? = nil) {
        if let url = databaseURL {
            self.databaseURL = url
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let openduckDir = appSupport.appendingPathComponent("OpenDuck", isDirectory: true)
            try? FileManager.default.createDirectory(at: openduckDir, withIntermediateDirectories: true)
            self.databaseURL = openduckDir.appendingPathComponent("metadata.sqlite")
        }

        openDatabase()
        createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func openDatabase() {
        lock.lock()
        defer { lock.unlock() }

        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            print("🛑 [MetadataDatabase] Error opening database: \(errmsg)")
            return
        }

        // Enable Write-Ahead Logging (WAL) for high concurrency
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("⚠️ [MetadataDatabase] WAL mode warning: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    private func createTables() {
        let schema = """
        CREATE TABLE IF NOT EXISTS file_records (
            id TEXT PRIMARY KEY,
            volume_name TEXT NOT NULL,
            remote_path TEXT NOT NULL,
            local_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            is_placeholder INTEGER NOT NULL DEFAULT 1,
            state TEXT NOT NULL DEFAULT 'placeholder',
            etag TEXT,
            remote_mtime REAL NOT NULL DEFAULT 0,
            local_mtime REAL NOT NULL DEFAULT 0,
            last_synced REAL NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_records_local ON file_records(local_path);
        CREATE INDEX IF NOT EXISTS idx_records_volume_remote ON file_records(volume_name, remote_path);

        CREATE TABLE IF NOT EXISTS pinned_host_keys (
            host_port TEXT PRIMARY KEY,
            key_type TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            pinned_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS divergence_events (
            id TEXT PRIMARY KEY,
            volume_name TEXT NOT NULL,
            path TEXT NOT NULL,
            reason TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
        """

        lock.lock()
        defer { lock.unlock() }

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, schema, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("🛑 [MetadataDatabase] Schema error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    // MARK: - Upsert & Query Operations

    public func upsert(_ record: FileRecord) {
        let sql = """
        INSERT INTO file_records (
            id, volume_name, remote_path, local_path, file_name,
            size, is_placeholder, state, etag,
            remote_mtime, local_mtime, last_synced, is_pinned
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(local_path) DO UPDATE SET
            size = excluded.size,
            is_placeholder = excluded.is_placeholder,
            state = excluded.state,
            etag = excluded.etag,
            remote_mtime = excluded.remote_mtime,
            local_mtime = excluded.local_mtime,
            last_synced = excluded.last_synced,
            is_pinned = excluded.is_pinned;
        """

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (record.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (record.volumeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (record.remotePath as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (record.localPath as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (record.fileName as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 6, record.size)
            sqlite3_bind_int(stmt, 7, record.isPlaceholder ? 1 : 0)
            sqlite3_bind_text(stmt, 8, (record.state.rawValue as NSString).utf8String, -1, nil)
            if let etag = record.etag {
                sqlite3_bind_text(stmt, 9, (etag as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_double(stmt, 10, record.remoteMtime.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 11, record.localMtime.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 12, record.lastSynced.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 13, record.isPinned ? 1 : 0)

            if sqlite3_step(stmt) != SQLITE_DONE {
                let err = String(cString: sqlite3_errmsg(db))
                print("🛑 [MetadataDatabase] Upsert failed: \(err)")
            }
        }
        sqlite3_finalize(stmt)
    }

    public func record(forLocalPath localPath: String) -> FileRecord? {
        let sql = "SELECT id, volume_name, remote_path, local_path, file_name, size, is_placeholder, state, etag, remote_mtime, local_mtime, last_synced, is_pinned FROM file_records WHERE local_path = ? LIMIT 1;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        var result: FileRecord?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (localPath as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                result = parseRecord(from: stmt)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    public func record(forRemotePath remotePath: String, volumeName: String) -> FileRecord? {
        let sql = "SELECT id, volume_name, remote_path, local_path, file_name, size, is_placeholder, state, etag, remote_mtime, local_mtime, last_synced, is_pinned FROM file_records WHERE volume_name = ? AND remote_path = ? LIMIT 1;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        var result: FileRecord?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (volumeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (remotePath as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                result = parseRecord(from: stmt)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    public func isPlaceholder(localPath: String) -> Bool {
        guard let r = record(forLocalPath: localPath) else { return false }
        return r.isPlaceholder || r.state == .placeholder
    }

    public func markPlaceholder(
        localPath: String,
        remotePath: String,
        volumeName: String,
        fileName: String,
        size: Int64,
        remoteMtime: Date
    ) {
        let record = FileRecord(
            volumeName: volumeName,
            remotePath: remotePath,
            localPath: localPath,
            fileName: fileName,
            size: size,
            isPlaceholder: true,
            state: .placeholder,
            remoteMtime: remoteMtime,
            localMtime: Date(),
            lastSynced: Date(),
            isPinned: false
        )
        upsert(record)
    }

    public func markMaterialized(localPath: String) {
        let sql = "UPDATE file_records SET is_placeholder = 0, state = 'materialized', local_mtime = ? WHERE local_path = ?;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (localPath as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func markDirty(localPath: String) {
        let sql = "UPDATE file_records SET state = 'dirty', is_placeholder = 0, local_mtime = ? WHERE local_path = ?;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (localPath as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func markClean(localPath: String, remoteMtime: Date, size: Int64) {
        let sql = "UPDATE file_records SET state = 'materialized', is_placeholder = 0, size = ?, remote_mtime = ?, last_synced = ? WHERE local_path = ?;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, size)
            sqlite3_bind_double(stmt, 2, remoteMtime.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, (localPath as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func deleteRecord(localPath: String) {
        let sql = "DELETE FROM file_records WHERE local_path = ?;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (localPath as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func allPlaceholders(forVolume volumeName: String) -> Set<String> {
        let sql = "SELECT local_path FROM file_records WHERE volume_name = ? AND is_placeholder = 1;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        var paths = Set<String>()

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (volumeName as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    paths.insert(String(cString: cStr))
                }
            }
        }
        sqlite3_finalize(stmt)
        return paths
    }

    public func allDirtyRecords() -> [FileRecord] {
        let sql = "SELECT id, volume_name, remote_path, local_path, file_name, size, is_placeholder, state, etag, remote_mtime, local_mtime, last_synced, is_pinned FROM file_records WHERE state = 'dirty';"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        var records: [FileRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let r = parseRecord(from: stmt) {
                    records.append(r)
                }
            }
        }
        sqlite3_finalize(stmt)
        return records
    }

    public func clearVolume(volumeName: String) {
        let sql = "DELETE FROM file_records WHERE volume_name = ?;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (volumeName as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Host Key Pinning (TOFU)

    public func pinnedFingerprint(forHost host: String, port: Int) -> String? {
        let key = "\(host):\(port)"
        let sql = "SELECT fingerprint FROM pinned_host_keys WHERE host_port = ? LIMIT 1;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        var result: String?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    result = String(cString: cStr)
                }
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    public func pinHostKey(host: String, port: Int, keyType: String, fingerprint: String) {
        let key = "\(host):\(port)"
        let sql = """
        INSERT INTO pinned_host_keys (host_port, key_type, fingerprint, pinned_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(host_port) DO UPDATE SET
            key_type = excluded.key_type,
            fingerprint = excluded.fingerprint,
            pinned_at = excluded.pinned_at;
        """

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (keyType as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (fingerprint as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Divergence Events (Circuit Breaker & Desync Tracking)

    public struct DivergenceEvent: Sendable, Codable, Identifiable {
        public let id: String
        public let volumeName: String
        public let path: String
        public let reason: String
        public let timestamp: Date
    }

    public func recordDivergenceEvent(volumeName: String, path: String, reason: String) {
        let sql = "INSERT INTO divergence_events (id, volume_name, path, reason, timestamp) VALUES (?, ?, ?, ?, ?);"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (UUID().uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (volumeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (reason as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    public func allDivergenceEvents() -> [DivergenceEvent] {
        let sql = "SELECT id, volume_name, path, reason, timestamp FROM divergence_events ORDER BY timestamp DESC;"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        var events: [DivergenceEvent] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let volumeName = String(cString: sqlite3_column_text(stmt, 1))
                let path = String(cString: sqlite3_column_text(stmt, 2))
                let reason = String(cString: sqlite3_column_text(stmt, 3))
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))

                events.append(DivergenceEvent(
                    id: id,
                    volumeName: volumeName,
                    path: path,
                    reason: reason,
                    timestamp: timestamp
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    private func parseRecord(from stmt: OpaquePointer?) -> FileRecord? {
        guard let stmt = stmt else { return nil }

        let id = String(cString: sqlite3_column_text(stmt, 0))
        let volumeName = String(cString: sqlite3_column_text(stmt, 1))
        let remotePath = String(cString: sqlite3_column_text(stmt, 2))
        let localPath = String(cString: sqlite3_column_text(stmt, 3))
        let fileName = String(cString: sqlite3_column_text(stmt, 4))
        let size = sqlite3_column_int64(stmt, 5)
        let isPlaceholder = sqlite3_column_int(stmt, 6) != 0
        let stateStr = String(cString: sqlite3_column_text(stmt, 7))
        let state = ItemSyncState(rawValue: stateStr) ?? .placeholder

        var etag: String?
        if let etagCStr = sqlite3_column_text(stmt, 8) {
            etag = String(cString: etagCStr)
        }

        let remoteMtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let localMtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let lastSynced = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let isPinned = sqlite3_column_int(stmt, 12) != 0

        return FileRecord(
            id: id,
            volumeName: volumeName,
            remotePath: remotePath,
            localPath: localPath,
            fileName: fileName,
            size: size,
            isPlaceholder: isPlaceholder,
            state: state,
            etag: etag,
            remoteMtime: remoteMtime,
            localMtime: localMtime,
            lastSynced: lastSynced,
            isPinned: isPinned
        )
    }
}
