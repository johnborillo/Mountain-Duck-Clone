import Foundation
import FileProvider
import OpenDuckCore

final class SharedAccessTests: XCTestCase {
    func testSSHBookmarkMetadataUsesSharedStoreAndDeletesCleanly() {
        let suiteName = "com.openduck.tests.bookmarks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SSHKeyBookmarkStore(userDefaults: defaults)
        let profileID = UUID()
        let bookmark = Data([0x01, 0x02, 0x03])

        XCTAssertFalse(store.hasBookmark(for: profileID))
        store.saveBookmark(bookmark, for: profileID)
        XCTAssertEqual(store.bookmark(for: profileID), bookmark)
        store.deleteBookmark(for: profileID)
        XCTAssertFalse(store.hasBookmark(for: profileID))
    }

    func testRegistrationDiagnosticsIncludeNestedErrorCodes() {
        let underlying = NSError(
            domain: NSCocoaErrorDomain,
            code: 4099,
            userInfo: [NSLocalizedDescriptionKey: "Connection interrupted"]
        )
        let outer = NSError(
            domain: "NSFileProviderErrorDomain",
            code: -2001,
            userInfo: [
                NSLocalizedDescriptionKey: "Application cannot be used right now",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let description = FileProviderDomainCoordinator.diagnosticDescription(for: outer)
        XCTAssertTrue(description.contains("NSFileProviderErrorDomain -2001"))
        XCTAssertTrue(description.contains("NSCocoaErrorDomain 4099"))
    }

    func testAdapterErrorsAreMappedToSupportedFileProviderErrors() {
        let authentication = FileProviderErrorMapper.map(
            AdapterError.authenticationFailed("missing key permission")
        ) as NSError
        XCTAssertEqual(authentication.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(authentication.code, NSFileProviderError.notAuthenticated.rawValue)
        XCTAssertTrue(authentication.userInfo[NSUnderlyingErrorKey] is NSError)

        let missingProfile = FileProviderErrorMapper.map(
            AdapterError.invalidPath("Server profile not found")
        ) as NSError
        XCTAssertEqual(missingProfile.domain, NSFileProviderErrorDomain)
        XCTAssertEqual(missingProfile.code, NSFileProviderError.cannotSynchronize.rawValue)
    }
}
