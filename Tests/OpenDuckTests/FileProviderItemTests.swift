import Foundation
import Testing
import FileProvider
import UniformTypeIdentifiers
@testable import OpenDuckCore

@Suite struct FileProviderItemTests {
    @Test func itemCreationFromEntry() {
        let entry = RemoteFileEntry(
            name: "document.pdf",
            path: "/books/document.pdf",
            itemType: .file,
            size: 2048,
            modificationDate: Date()
        )

        let parentId = NSFileProviderItemIdentifier("parent-folder-id")
        let item = FileProviderItem(from: entry, parentIdentifier: parentId, isDownloaded: true)

        #expect(item.filename == "document.pdf")
        #expect(item.parentItemIdentifier == parentId)
        #expect(item.documentSize?.int64Value == 2048)
        #expect(item.contentType == .pdf)
        #expect(item.isDownloaded)
        #expect(!item.isDirectory)
        #expect(item.capabilities.contains(.allowsReading))
        #expect(item.capabilities.contains(.allowsWriting))
    }

    @Test func directoryItemCapabilities() {
        let entry = RemoteFileEntry(
            name: "photos",
            path: "/media/photos",
            itemType: .directory
        )

        let item = FileProviderItem(from: entry, parentIdentifier: .rootContainer)
        #expect(item.contentType == .folder)
        #expect(item.isDirectory)
        #expect(item.documentSize == nil)
        #expect(item.capabilities.contains(.allowsAddingSubItems))
        #expect(item.capabilities.contains(.allowsContentEnumerating))
    }
}

