import Foundation
import XCTest
import FileProvider
import UniformTypeIdentifiers
@testable import OpenDuckCore

final class FileProviderItemTests: XCTestCase {
    func testItemCreationFromEntry() {
        let entry = RemoteFileEntry(
            name: "document.pdf",
            path: "/books/document.pdf",
            itemType: .file,
            size: 2048,
            modificationDate: Date()
        )

        let parentId = NSFileProviderItemIdentifier("parent-folder-id")
        let item = FileProviderItem(from: entry, parentIdentifier: parentId, isDownloaded: true)

        XCTAssertEqual(item.filename, "document.pdf")
        XCTAssertEqual(item.parentItemIdentifier, parentId)
        XCTAssertEqual(item.documentSize?.int64Value, 2048)
        XCTAssertEqual(item.contentType, .pdf)
        XCTAssertTrue(item.isDownloaded)
        XCTAssertFalse(item.isDirectory)
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
    }

    func testDirectoryItemCapabilities() {
        let entry = RemoteFileEntry(
            name: "photos",
            path: "/media/photos",
            itemType: .directory
        )

        let item = FileProviderItem(from: entry, parentIdentifier: .rootContainer)
        XCTAssertEqual(item.contentType, .folder)
        XCTAssertTrue(item.isDirectory)
        XCTAssertNil(item.documentSize)
        XCTAssertTrue(item.capabilities.contains(.allowsAddingSubItems))
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
    }
}
