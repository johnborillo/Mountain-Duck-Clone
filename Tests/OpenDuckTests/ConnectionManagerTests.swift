import Foundation
import XCTest
@testable import OpenDuckCore

final class ConnectionManagerTests: XCTestCase {
    func testProfileRegistrationAndRetrieval() {
        let manager = ConnectionManager()
        let profile = ServerProfile(
            name: "Test SFTP",
            protocolType: .sftp,
            host: "sftp.example.com",
            username: "admin",
            remoteRootPath: "/var/www"
        )

        manager.registerProfile(profile)
        let all = manager.allProfiles()
        XCTAssertTrue(all.contains { $0.id == profile.id })
    }

    func testMockConnectionLifecycle() async throws {
        let manager = ConnectionManager()
        let profile = ServerProfile(
            name: "Mock Server",
            protocolType: .mock
        )

        manager.registerProfile(profile)
        let adapter = try await manager.connect(to: profile.id)
        XCTAssertTrue(adapter.isConnected)

        let active = manager.activeAdapter(for: profile.id)
        XCTAssertNotNil(active)
        XCTAssertTrue(active?.isConnected == true)

        await manager.disconnect(from: profile.id)
        XCTAssertNil(manager.activeAdapter(for: profile.id))
    }
}
