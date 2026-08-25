import Foundation
import SQLite3

/// The durable identity and change-log record used by the native File Provider domain.
///
/// File Provider identifiers must not be derived from a path: a rename changes a path,
/// while Finder expects the item's identity to remain stable. This store keeps the mapping
/// between a remote path and a stable UUID and records mutations for change enumeration.
public struct DomainMetadataItem: Sendable, Equatable {
    public let itemIdentifier: String
    public var parentItemIdentifier: String
    public var filename: String
    public var remotePath: String
    public var itemType: RemoteItemType
    public var size: Int64
    public var modificationDate: Date
    public var creationDate: Date?
    public var contentVersion: String
    public var metadataVersion: String
    public var isDeleted: Bool

    public var isDirectory: Bool { itemType == .directory }

    public init(
        itemIdentifier: String,
        parentItemIdentifier: String,
        filename: String,
        remotePath: String,
        itemType: RemoteItemType,
        size: Int64,
        modificationDate: Date,
        creationDate: Date?,
        contentVersion: String,
        metadataVersion: String,
        isDeleted: Bool = false
    ) {
        self.itemIdentifier = itemIdentifier
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = filename
        self.remotePath = remotePath
        self.itemType = itemType
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.isDeleted = isDeleted
    }
}

public struct DomainMetadataChange: Sendable, Equatable {
    public enum Kind: String, Sendable { case upsert, delete }

    public let sequence: Int64
    public let itemIdentifier: String
    public let kind: Kind

    public init(sequence: Int64, itemIdentifier: String, kind: Kind) {
        self.sequence = sequence
        self.itemIdentifier = itemIdentifier
        self.kind = kind
    }
}

/// SQLite-backed metadata for one or more File Provider domains.
///
/// The store is intentionally independent of the legacy volume metadata database. Native
/// domains can be removed and re-added without losing stable IDs or the change anchor, and
/// the injected database URL makes the behavior straightforward to test in isolation.
public final class DomainMetadataStore: @unchecked Sendable {
    public static let shared = DomainMetadataStore()

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let databaseURL: URL

    public init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            self.databaseURL = OpenDuckSharedStorage.baseDirectory.appendingPathComponent("domain-metadata.sqlite")
        }
        try? FileManager.default.createDirectory(at: self.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        openDatabase()
        createTables()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func item(for itemIdentifier: String, domainIdentifier: String) -> DomainMetadataItem? {
        queryItem(sql: "SELECT item_id, parent_id, filename, remote_path, item_type, size, modified_at, created_at, content_version, metadata_version, is_deleted FROM domain_items WHERE domain_id = ? AND item_id = ? LIMIT 1;", bindings: [domainIdentifier, itemIdentifier])
    }

    public func item(forRemotePath remotePath: String, domainIdentifier: String) -> DomainMetadataItem? {
        queryItem(sql: "SELECT item_id, parent_id, filename, remote_path, item_type, size, modified_at, created_at, content_version, metadata_version, is_deleted FROM domain_items WHERE domain_id = ? AND remote_path = ? LIMIT 1;", bindings: [domainIdentifier, normalize(remotePath)])
    }

    public func items(for identifiers: [String], domainIdentifier: String) -> [DomainMetadataItem] {
        identifiers.compactMap { item(for: $0, domainIdentifier: domainIdentifier) }
    }

    public func items(forParentItemIdentifier parentItemIdentifier: String, domainIdentifier: String) -> [DomainMetadataItem] {
        lock.lock()
        defer { lock.unlock() }
        return queryItemsUnlocked(
            sql: "SELECT item_id, parent_id, filename, remote_path, item_type, size, modified_at, created_at, content_version, metadata_version, is_deleted FROM domain_items WHERE domain_id = ? AND parent_id = ?;",
            bindings: [domainIdentifier, parentItemIdentifier]
        )
    }

    /// Insert or update an item while preserving its existing identity for the same remote path.
    @discardableResult
    public func upsert(
        domainIdentifier: String,
        parentItemIdentifier: String,
        entry: RemoteFileEntry,
        itemIdentifier requestedIdentifier: String? = nil
    ) -> DomainMetadataItem {
        lock.lock()
        defer { lock.unlock() }

        let path = normalize(entry.path)
        let existing = queryItemUnlocked(
            sql: "SELECT item_id, parent_id, filename, remote_path, item_type, size, modified_at, created_at, content_version, metadata_version, is_deleted FROM domain_items WHERE domain_id = ? AND (remote_path = ? OR item_id = ?) LIMIT 1;",
            bindings: [domainIdentifier, path, requestedIdentifier ?? ""]
        )
        let id = existing?.itemIdentifier ?? requestedIdentifier ?? UUID().uuidString
        let contentVersion = entry.etag ?? "\(entry.modificationDate.timeIntervalSince1970):\(entry.size)"
        let metadataVersion = "\(entry.name)|\(parentItemIdentifier)|\(entry.modificationDate.timeIntervalSince1970)"
        let record = DomainMetadataItem(
            itemIdentifier: id,
            parentItemIdentifier: parentItemIdentifier,
            filename: entry.name,
            remotePath: path,
            itemType: entry.itemType,
            size: entry.size,
            modificationDate: entry.modificationDate,
            creationDate: entry.creationDate,
            contentVersion: contentVersion,
            metadataVersion: metadataVersion
        )

        if existing == record { return existing! }
        executeUnlocked("""
            INSERT INTO domain_items (domain_id, item_id, parent_id, filename, remote_path, item_type, size, modified_at, created_at, content_version, metadata_version, is_deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(domain_id, item_id) DO UPDATE SET
              parent_id = excluded.parent_id, filename = excluded.filename, remote_path = excluded.remote_path,
              item_type = excluded.item_type, size = excluded.size, modified_at = excluded.modified_at,
              created_at = excluded.created_at, content_version = excluded.content_version,
              metadata_version = excluded.metadata_version, is_deleted = 0;
            """, bindings: [domainIdentifier, record.itemIdentifier, record.parentItemIdentifier, record.filename, record.remotePath, record.itemType.rawValue, record.size, record.modificationDate.timeIntervalSince1970, record.creationDate?.timeIntervalSince1970 as Any? ?? NSNull(), record.contentVersion, record.metadataVersion])
        appendChangeUnlocked(domainIdentifier: domainIdentifier, itemIdentifier: record.itemIdentifier, kind: .upsert)
        return record
    }

    /// Update identity and path for a move/rename. Descendants are rewritten as one operation.
    @discardableResult
    public func move(domainIdentifier: String, itemIdentifier: String, parentItemIdentifier: String, filename: String, remotePath: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let item = queryItemUnlocked(sql: "SELECT item_id, parent_id, filename, remote_path, item_type, size, modified_at, created_at, content_version, metadata_version, is_deleted FROM domain_items WHERE domain_id = ? AND item_id = ? LIMIT 1;", bindings: [domainIdentifier, itemIdentifier]) else { return 0 }

        let oldPrefix = item.remotePath
        let newPrefix = normalize(remotePath)
        let childPattern = oldPrefix.hasSuffix("/") ? oldPrefix + "%" : oldPrefix + "/%"
        let newChildPrefix = newPrefix.hasSuffix("/") ? newPrefix : newPrefix + "/"
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        executeUnlocked("""
            UPDATE domain_items SET
              remote_path = CASE WHEN remote_path = ? THEN ? ELSE ? || substr(remote_path, ?) END,
              parent_id = CASE WHEN item_id = ? THEN ? ELSE parent_id END,
              filename = CASE WHEN item_id = ? THEN ? ELSE filename END,
              metadata_version = ?
            WHERE domain_id = ? AND (remote_path = ? OR remote_path LIKE ? ESCAPE '\\');
            """, bindings: [oldPrefix, newPrefix, newChildPrefix, oldPrefix.utf8.count + 1, itemIdentifier, parentItemIdentifier, itemIdentifier, filename, UUID().uuidString, domainIdentifier, oldPrefix, escapeLike(childPattern)])
        let changed = Int(sqlite3_changes(db))
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        if changed > 0 { appendChangeUnlocked(domainIdentifier: domainIdentifier, itemIdentifier: itemIdentifier, kind: .upsert) }
        return changed
    }

    public func markDeleted(domainIdentifier: String, itemIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        executeUnlocked("UPDATE domain_items SET is_deleted = 1, metadata_version = ? WHERE domain_id = ? AND item_id = ?;", bindings: [UUID().uuidString, domainIdentifier, itemIdentifier])
        if sqlite3_changes(db) > 0 { appendChangeUnlocked(domainIdentifier: domainIdentifier, itemIdentifier: itemIdentifier, kind: .delete) }
    }

    public func changes(domainIdentifier: String, after sequence: Int64, limit: Int = 500) -> [DomainMetadataChange] {
        lock.lock()
        defer { lock.unlock() }
        var output: [DomainMetadataChange] = []
        let sql = "SELECT sequence, item_id, kind FROM domain_changes WHERE domain_id = ? AND sequence > ? ORDER BY sequence ASC LIMIT ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bind(statement, 1, domainIdentifier); sqlite3_bind_int64(statement, 2, sequence); sqlite3_bind_int(statement, 3, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let itemID = sqlite3_column_text(statement, 1), let kindRaw = sqlite3_column_text(statement, 2), let kind = DomainMetadataChange.Kind(rawValue: String(cString: kindRaw)) else { continue }
                output.append(DomainMetadataChange(sequence: sqlite3_column_int64(statement, 0), itemIdentifier: String(cString: itemID), kind: kind))
            }
        }
        sqlite3_finalize(statement)
        return output
    }

    public func currentSequence(domainIdentifier: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT COALESCE(MAX(sequence), 0) FROM domain_changes WHERE domain_id = ?;"
        var statement: OpaquePointer?
        var value: Int64 = 0
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK { bind(statement, 1, domainIdentifier); if sqlite3_step(statement) == SQLITE_ROW { value = sqlite3_column_int64(statement, 0) } }
        sqlite3_finalize(statement)
        return value
    }

    public func anchor(for sequence: Int64) -> Data { Data(String(sequence).utf8) }

    public func sequence(from anchor: Data) -> Int64 { Int64(String(data: anchor, encoding: .utf8) ?? "0") ?? 0 }

    // MARK: - SQLite plumbing

    private func openDatabase() {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { return }
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
    }

    private func createTables() {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS domain_items (
              domain_id TEXT NOT NULL, item_id TEXT NOT NULL, parent_id TEXT NOT NULL,
              filename TEXT NOT NULL, remote_path TEXT NOT NULL, item_type TEXT NOT NULL,
              size INTEGER NOT NULL DEFAULT 0, modified_at REAL NOT NULL, created_at REAL,
              content_version TEXT NOT NULL, metadata_version TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(domain_id, item_id), UNIQUE(domain_id, remote_path)
            );
            CREATE INDEX IF NOT EXISTS idx_domain_items_parent ON domain_items(domain_id, parent_id);
            CREATE TABLE IF NOT EXISTS domain_changes (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT, domain_id TEXT NOT NULL,
              item_id TEXT NOT NULL, kind TEXT NOT NULL, created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_domain_changes_domain ON domain_changes(domain_id, sequence);
            """, nil, nil, nil)
    }

    private func appendChangeUnlocked(domainIdentifier: String, itemIdentifier: String, kind: DomainMetadataChange.Kind) {
        executeUnlocked("INSERT INTO domain_changes(domain_id, item_id, kind, created_at) VALUES (?, ?, ?, ?);", bindings: [domainIdentifier, itemIdentifier, kind.rawValue, Date().timeIntervalSince1970])
    }

    private func queryItem(sql: String, bindings: [Any]) -> DomainMetadataItem? {
        lock.lock(); defer { lock.unlock() }
        return queryItemUnlocked(sql: sql, bindings: bindings)
    }

    private func queryItemUnlocked(sql: String, bindings: [Any]) -> DomainMetadataItem? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bindAll(statement, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let itemID = sqlite3_column_text(statement, 0), let parentID = sqlite3_column_text(statement, 1), let filename = sqlite3_column_text(statement, 2), let path = sqlite3_column_text(statement, 3), let typeRaw = sqlite3_column_text(statement, 4), let itemType = RemoteItemType(rawValue: String(cString: typeRaw)), let content = sqlite3_column_text(statement, 8), let metadata = sqlite3_column_text(statement, 9) else { return nil }
        return DomainMetadataItem(itemIdentifier: String(cString: itemID), parentItemIdentifier: String(cString: parentID), filename: String(cString: filename), remotePath: String(cString: path), itemType: itemType, size: sqlite3_column_int64(statement, 5), modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), creationDate: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)), contentVersion: String(cString: content), metadataVersion: String(cString: metadata), isDeleted: sqlite3_column_int(statement, 10) != 0)
    }

    private func queryItemsUnlocked(sql: String, bindings: [Any]) -> [DomainMetadataItem] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        bindAll(statement, bindings)
        defer { sqlite3_finalize(statement) }
        var output: [DomainMetadataItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let itemID = sqlite3_column_text(statement, 0), let parentID = sqlite3_column_text(statement, 1), let filename = sqlite3_column_text(statement, 2), let path = sqlite3_column_text(statement, 3), let typeRaw = sqlite3_column_text(statement, 4), let itemType = RemoteItemType(rawValue: String(cString: typeRaw)), let content = sqlite3_column_text(statement, 8), let metadata = sqlite3_column_text(statement, 9) else { continue }
            output.append(DomainMetadataItem(itemIdentifier: String(cString: itemID), parentItemIdentifier: String(cString: parentID), filename: String(cString: filename), remotePath: String(cString: path), itemType: itemType, size: sqlite3_column_int64(statement, 5), modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), creationDate: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)), contentVersion: String(cString: content), metadataVersion: String(cString: metadata), isDeleted: sqlite3_column_int(statement, 10) != 0))
        }
        return output
    }

    private func executeUnlocked(_ sql: String, bindings: [Any]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bindAll(statement, bindings); _ = sqlite3_step(statement); sqlite3_finalize(statement)
    }

    private func bindAll(_ statement: OpaquePointer?, _ values: [Any]) { for (index, value) in values.enumerated() { bind(statement, Int32(index + 1), value) } }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Any) {
        switch value {
        case let string as String: sqlite3_bind_text(statement, index, (string as NSString).utf8String, -1, nil)
        case let int as Int64: sqlite3_bind_int64(statement, index, int)
        case let int as Int: sqlite3_bind_int64(statement, index, Int64(int))
        case let double as Double: sqlite3_bind_double(statement, index, double)
        case _ as NSNull: sqlite3_bind_null(statement, index)
        default: sqlite3_bind_null(statement, index)
        }
    }

    private func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/" + trimmed
    }

    private func escapeLike(_ pattern: String) -> String {
        let literal = pattern.hasSuffix("%") ? String(pattern.dropLast()) : pattern
        return literal.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + (pattern.hasSuffix("%") ? "%" : "")
    }
}
