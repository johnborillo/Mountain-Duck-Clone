import Foundation
import OpenDuckCore

final class RemotePathTests: XCTestCase {
    func testNormalizationAndJoining() {
        XCTAssertEqual(RemotePath.normalize("/home/user/../docs//report.txt"), "/home/docs/report.txt")
        XCTAssertEqual(RemotePath.join("/home/user", "folder/report.txt"), "/home/user/folder/report.txt")
        XCTAssertEqual(RemotePath.join("/", "file.txt"), "/file.txt")
    }

    func testRootConfinementRejectsTraversalAndSiblingPrefix() {
        XCTAssertTrue(RemotePath.isWithin("/home/user/docs/file.txt", root: "/home/user"))
        XCTAssertFalse(RemotePath.isWithin("/home/user/../admin", root: "/home/user"))
        XCTAssertFalse(RemotePath.isWithin("/home/user-old/file.txt", root: "/home/user"))
        XCTAssertEqual(RemotePath.relativePath(of: "/home/user/docs/file.txt", from: "/home/user"), "docs/file.txt")
        XCTAssertNil(RemotePath.relativePath(of: "/tmp/file.txt", from: "/home/user"))
    }
}
