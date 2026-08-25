import Foundation
import OpenDuckCore

final class DomainMetadataStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("openduck-domain-(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("shm"))
        try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("wal"))
    }

    func testIdentitySurvivesMetadataRefresh() {
        let store = DomainMetadataStore(databaseURL: databaseURL)
        let first = store.upsert(
            domainIdentifier: "domain-a",
            parentItemIdentifier: "root",
            entry: RemoteFileEntry(name: "report.txt", path: "/reports/report.txt", size: 10)
        )
        let second = store.upsert(
            domainIdentifier: "domain-a",
            parentItemIdentifier: "root",
            entry: RemoteFileEntry(name: "report.txt", path: "/reports/report.txt", size: 25, modificationDate: Date(timeIntervalSince1970: 100))
        )

        XCTAssertEqual(first.itemIdentifier, second.itemIdentifier)
        XCTAssertEqual(store.item(forRemotePath: "/reports/report.txt", domainIdentifier: "domain-a")?.size, 25)
        XCTAssertGreaterThan(store.currentSequence(domainIdentifier: "domain-a"), 0)

        let reopened = DomainMetadataStore(databaseURL: databaseURL)
        XCTAssertEqual(reopened.item(forRemotePath: "/reports/report.txt", domainIdentifier: "domain-a")?.itemIdentifier, first.itemIdentifier)
        XCTAssertEqual(reopened.currentSequence(domainIdentifier: "domain-a"), store.currentSequence(domainIdentifier: "domain-a"))
    }

    func testRenamePreservesIdentityAndEmitsChange() {
        let store = DomainMetadataStore(databaseURL: databaseURL)
        let entry = RemoteFileEntry(name: "old.txt", path: "/old.txt", size: 3)
        let item = store.upsert(domainIdentifier: "domain-a", parentItemIdentifier: "root", entry: entry)
        let beforeMove = store.currentSequence(domainIdentifier: "domain-a")

        XCTAssertEqual(store.move(domainIdentifier: "domain-a", itemIdentifier: item.itemIdentifier, parentItemIdentifier: "root", filename: "new.txt", remotePath: "/new.txt"), 1)
        let moved = store.item(for: item.itemIdentifier, domainIdentifier: "domain-a")
        XCTAssertEqual(moved?.itemIdentifier, item.itemIdentifier)
        XCTAssertEqual(moved?.remotePath, "/new.txt")
        XCTAssertEqual(moved?.filename, "new.txt")
        XCTAssertGreaterThan(store.currentSequence(domainIdentifier: "domain-a"), beforeMove)
    }

    func testDeleteIsARecoverableTombstone() {
        let store = DomainMetadataStore(databaseURL: databaseURL)
        let item = store.upsert(
            domainIdentifier: "domain-a",
            parentItemIdentifier: "root",
            entry: RemoteFileEntry(name: "gone.txt", path: "/gone.txt")
        )
        store.markDeleted(domainIdentifier: "domain-a", itemIdentifier: item.itemIdentifier)

        XCTAssertTrue(store.item(for: item.itemIdentifier, domainIdentifier: "domain-a")?.isDeleted == true)
        let changes = store.changes(domainIdentifier: "domain-a", after: 0)
        XCTAssertTrue(changes.contains { $0.itemIdentifier == item.itemIdentifier && $0.kind == .delete })
    }
}
