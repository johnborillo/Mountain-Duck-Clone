import Foundation
import FileProvider
import UniformTypeIdentifiers

/// Bridge representation conforming to Apple's `NSFileProviderItem` protocol for Finder presentation.
public final class FileProviderItem: NSObject, NSFileProviderItem {
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let isDirectory: Bool
    public let documentSize: NSNumber?
    public let contentModificationDate: Date?
    public let creationDate: Date?
    public let isPinned: Bool
    public let isDownloaded: Bool
    public let isUploaded: Bool
    private let contentVersionData: Data?
    private let metadataVersionData: Data?

    public init(
        itemIdentifier: NSFileProviderItemIdentifier,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        isDirectory: Bool,
        documentSize: Int64 = 0,
        contentModificationDate: Date = Date(),
        creationDate: Date? = nil,
        isPinned: Bool = false,
        isDownloaded: Bool = true,
        isUploaded: Bool = true,
        contentVersion: String? = nil,
        metadataVersion: String? = nil
    ) {
        self.itemIdentifier = itemIdentifier
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = filename
        self.isDirectory = isDirectory
        self.documentSize = isDirectory ? nil : NSNumber(value: documentSize)
        self.contentModificationDate = contentModificationDate
        self.creationDate = creationDate
        self.isPinned = isPinned
        self.isDownloaded = isDownloaded
        self.isUploaded = isUploaded
        self.contentVersionData = contentVersion?.data(using: .utf8)
        self.metadataVersionData = metadataVersion?.data(using: .utf8)

        if isDirectory {
            self.contentType = .folder
        } else {
            let ext = (filename as NSString).pathExtension
            // Foundation can return a dynamic UTI for a well-known extension
            // when the app-extension process has not loaded the system type
            // declarations yet. Preserve canonical public types where Finder
            // relies on them for presentation and Quick Look.
            if ext.caseInsensitiveCompare("pdf") == .orderedSame {
                self.contentType = .pdf
            } else {
                self.contentType = UTType(filenameExtension: ext) ?? .data
            }
        }

        super.init()
    }

    public convenience init(from entry: RemoteFileEntry, parentIdentifier: NSFileProviderItemIdentifier, isDownloaded: Bool = false) {
        let identifier = NSFileProviderItemIdentifier(Data(entry.path.utf8).base64EncodedString())
        self.init(
            itemIdentifier: identifier,
            parentItemIdentifier: parentIdentifier,
            filename: entry.name,
            isDirectory: entry.isDirectory,
            documentSize: entry.size,
            contentModificationDate: entry.modificationDate,
            creationDate: entry.creationDate,
            isDownloaded: isDownloaded,
            isUploaded: true,
            contentVersion: entry.contentVersion,
            metadataVersion: entry.metadataVersion
        )
    }

    public convenience init(from metadata: DomainMetadataItem, isDownloaded: Bool = false) {
        self.init(
            itemIdentifier: NSFileProviderItemIdentifier(metadata.itemIdentifier),
            parentItemIdentifier: NSFileProviderItemIdentifier(metadata.parentItemIdentifier),
            filename: metadata.filename,
            isDirectory: metadata.isDirectory,
            documentSize: metadata.size,
            contentModificationDate: metadata.modificationDate,
            creationDate: metadata.creationDate,
            isDownloaded: isDownloaded,
            isUploaded: !metadata.isDeleted,
            contentVersion: metadata.contentVersion,
            metadataVersion: metadata.metadataVersion
        )
    }

    public var capabilities: NSFileProviderItemCapabilities {
        if isDirectory {
            return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        } else {
            return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting]
        }
    }

    public var itemVersion: NSFileProviderItemVersion {
        let mtime = contentModificationDate?.timeIntervalSince1970 ?? 0
        let fallback = "\(mtime)".data(using: .utf8) ?? Data()
        return NSFileProviderItemVersion(
            contentVersion: contentVersionData ?? fallback,
            metadataVersion: metadataVersionData ?? fallback
        )
    }
}
