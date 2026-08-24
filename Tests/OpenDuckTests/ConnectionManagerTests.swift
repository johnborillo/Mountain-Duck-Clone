import Foundation
import Testing
@testable import OpenDuckCore

@Suite struct ConnectionManagerTests {
    @Test func profileRegistrationAndRetrieval() {
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
        #expect(all.contains { $0.id == profile.id })
    }

    @Test func mockConnectionLifecycle() async throws {
        let manager = ConnectionManager()
        let profile = ServerProfile(
            name: "Mock Server",
            protocolType: .mock
        )

        manager.registerProfile(profile)
        let adapter = try await manager.connect(to: profile.id)
        #expect(adapter.isConnected)

        let active = manager.activeAdapter(for: profile.id)
        #expect(active != nil)
        #expect(active?.isConnected == true)

        await manager.disconnect(from: profile.id)
        #expect(manager.activeAdapter(for: profile.id) == nil)
    }
}

