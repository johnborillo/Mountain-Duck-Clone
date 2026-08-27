import Foundation

@MainActor
func runAllTests() async throws {
    print("🧪 [OpenDuck Test Suite] Running test suites...")
    var passed = 0

    func runTest(_ name: String, block: () async throws -> Void) async {
        do {
            try await block()
            print("  ✓ \(name)")
            passed += 1
        } catch {
            print("  🛑 FAIL: \(name) — \(error)")
            exit(1)
        }
    }

    // MockAdapterTests
    let mockTests = MockAdapterTests()
    await runTest("MockAdapterTests.testConnectionLifecycle") { try await mockTests.testConnectionLifecycle() }
    await runTest("MockAdapterTests.testDirectoryAndFileOperations") { try await mockTests.testDirectoryAndFileOperations() }
    await runTest("MockAdapterTests.testDisconnectedThrows") { await mockTests.testDisconnectedThrows() }

    // TransferProgressTests
    let progressTests = TransferProgressTests()
    try progressTests.setUpWithError()
    await runTest("TransferProgressTests.testTransferProgressFormatters") { progressTests.testTransferProgressFormatters() }
    await runTest("TransferProgressTests.testTransferTrackerLifecycleAndSpeedCalculation") { try await progressTests.testTransferTrackerLifecycleAndSpeedCalculation() }
    await runTest("TransferProgressTests.testMockAdapterChunkProgress") { try await progressTests.testMockAdapterChunkProgress() }
    try progressTests.tearDownWithError()

    // TransferPipelineTests (NEW)
    let pipelineTests = TransferPipelineTests()
    try pipelineTests.setUpWithError()
    await runTest("TransferPipelineTests.testAsyncTransferQueueConcurrencyLimiting") { await pipelineTests.testAsyncTransferQueueConcurrencyLimiting() }
    await runTest("TransferPipelineTests.testStreamingDownloadAndUploadIntegrity") { try await pipelineTests.testStreamingDownloadAndUploadIntegrity() }
    try pipelineTests.tearDownWithError()

    // HostKeyValidatorTests
    let hostKeyTests = HostKeyValidatorTests()
    try hostKeyTests.setUpWithError()
    await runTest("HostKeyValidatorTests.testFingerprintCalculationFormat") { hostKeyTests.testFingerprintCalculationFormat() }
    await runTest("HostKeyValidatorTests.testTofuFirstContactAndMismatchDetection") { try await hostKeyTests.testTofuFirstContactAndMismatchDetection() }
    await runTest("HostKeyValidatorTests.testFingerprintNormalizationAndLegacyPaddedHealing") { hostKeyTests.testFingerprintNormalizationAndLegacyPaddedHealing() }
    try hostKeyTests.tearDownWithError()

    // FileProviderItemTests
    let fpItemTests = FileProviderItemTests()
    await runTest("FileProviderItemTests.testItemCreationFromEntry") { fpItemTests.testItemCreationFromEntry() }
    await runTest("FileProviderItemTests.testDirectoryItemCapabilities") { fpItemTests.testDirectoryItemCapabilities() }
    await runTest("FileProviderItemTests.testItemVersionCarriesRemoteFingerprint") { fpItemTests.testItemVersionCarriesRemoteFingerprint() }

    // RemotePathTests
    let remotePathTests = RemotePathTests()
    await runTest("RemotePathTests.testNormalizationAndJoining") { remotePathTests.testNormalizationAndJoining() }
    await runTest("RemotePathTests.testRootConfinementRejectsTraversalAndSiblingPrefix") { remotePathTests.testRootConfinementRejectsTraversalAndSiblingPrefix() }

    // DomainMetadataStoreTests
    let domainMetadataTests = DomainMetadataStoreTests()
    try domainMetadataTests.setUpWithError()
    await runTest("DomainMetadataStoreTests.testIdentitySurvivesMetadataRefresh") { domainMetadataTests.testIdentitySurvivesMetadataRefresh() }
    await runTest("DomainMetadataStoreTests.testRenamePreservesIdentityAndEmitsChange") { domainMetadataTests.testRenamePreservesIdentityAndEmitsChange() }
    await runTest("DomainMetadataStoreTests.testDeleteIsARecoverableTombstone") { domainMetadataTests.testDeleteIsARecoverableTombstone() }
    await runTest("DomainMetadataStoreTests.testConflictLifecyclePersistsAndResolves") { domainMetadataTests.testConflictLifecyclePersistsAndResolves() }
    try domainMetadataTests.tearDownWithError()

    // DiagnosticsExporterTests
    let diagnosticsTests = DiagnosticsExporterTests()
    await runTest("DiagnosticsExporterTests.testReportIsReadableAndRedactsSecretLikePaths") { try diagnosticsTests.testReportIsReadableAndRedactsSecretLikePaths() }

    // ConnectionManagerTests
    let connTests = ConnectionManagerTests()
    await runTest("ConnectionManagerTests.testProfileRegistrationAndRetrieval") { connTests.testProfileRegistrationAndRetrieval() }
    await runTest("ConnectionManagerTests.testMockConnectionLifecycle") { try await connTests.testMockConnectionLifecycle() }

    // SharedAccessTests
    let sharedAccessTests = SharedAccessTests()
    await runTest("SharedAccessTests.testSSHBookmarkMetadataUsesSharedStoreAndDeletesCleanly") { sharedAccessTests.testSSHBookmarkMetadataUsesSharedStoreAndDeletesCleanly() }
    await runTest("SharedAccessTests.testImportedSSHKeyUsesOwnerOnlyStorageAndDeletesCleanly") { try sharedAccessTests.testImportedSSHKeyUsesOwnerOnlyStorageAndDeletesCleanly() }
    await runTest("SharedAccessTests.testRegistrationDiagnosticsIncludeNestedErrorCodes") { sharedAccessTests.testRegistrationDiagnosticsIncludeNestedErrorCodes() }
    await runTest("SharedAccessTests.testAdapterErrorsAreMappedToSupportedFileProviderErrors") { sharedAccessTests.testAdapterErrorsAreMappedToSupportedFileProviderErrors() }

    // CircuitBreakerTests
    let breakerTests = CircuitBreakerTests()
    try breakerTests.setUpWithError()
    await runTest("CircuitBreakerTests.testCircuitBreakerBurstAndSustainedTriggers") { try await breakerTests.testCircuitBreakerBurstAndSustainedTriggers() }
    try breakerTests.tearDownWithError()

    // CacheEngineTests
    let cacheTests = CacheEngineTests()
    try cacheTests.setUpWithError()
    await runTest("CacheEngineTests.testPlaceholderRegistration") { cacheTests.testPlaceholderRegistration() }
    await runTest("CacheEngineTests.testHydrationAndDirtySync") { try await cacheTests.testHydrationAndDirtySync() }
    await runTest("CacheEngineTests.testHydrationRejectsRemoteMutationDuringDownload") { try await cacheTests.testHydrationRejectsRemoteMutationDuringDownload() }
    await runTest("CacheEngineTests.testLruEvictionPolicy") { cacheTests.testLruEvictionPolicy() }
    await runTest("CacheEngineTests.testPurgeUnpinnedProtectsDirtyAndPinnedFiles") { try await cacheTests.testPurgeUnpinnedProtectsDirtyAndPinnedFiles() }
    await runTest("CacheEngineTests.testLatestPendingUploadIsPersistedAndSupersedesOlderSave") { try cacheTests.testLatestPendingUploadIsPersistedAndSupersedesOlderSave() }
    await runTest("CacheEngineTests.testMissingQueuedUploadIsRetainedForRecovery") { try await cacheTests.testMissingQueuedUploadIsRetainedForRecovery() }
    await runTest("CacheEngineTests.testBlockedConflictDoesNotReplayUntilExplicitlyUnblocked") { try await cacheTests.testBlockedConflictDoesNotReplayUntilExplicitlyUnblocked() }
    await runTest("CacheEngineTests.testEnqueueUploadStagesTransientSourceDurably") { try await cacheTests.testEnqueueUploadStagesTransientSourceDurably() }
    await runTest("CacheEngineTests.testReplayedDeleteMissingRemoteIsIdempotent") { try await cacheTests.testReplayedDeleteMissingRemoteIsIdempotent() }
    await runTest("CacheEngineTests.testReplayedMoveAfterRemoteSuccessIsIdempotent") { try await cacheTests.testReplayedMoveAfterRemoteSuccessIsIdempotent() }
    await runTest("CacheEngineTests.testQueuedRenameAndUploadPreserveBothOperations") { try cacheTests.testQueuedRenameAndUploadPreserveBothOperations() }
    await runTest("CacheEngineTests.testReplayedCreateDirectoryAlreadyExistsIsIdempotent") { try await cacheTests.testReplayedCreateDirectoryAlreadyExistsIsIdempotent() }
    try cacheTests.tearDownWithError()

    // DeleteSyncTests
    let deleteTests = DeleteSyncTests()
    try deleteTests.setUpWithError()
    await runTest("DeleteSyncTests.testFailedDeleteIsJournaledForRetry") { try await deleteTests.testFailedDeleteIsJournaledForRetry() }
    await runTest("DeleteSyncTests.testCircuitBreakerBlockedDeletesAreJournaled") { try await deleteTests.testCircuitBreakerBlockedDeletesAreJournaled() }
    await runTest("DeleteSyncTests.testHydratingPathTokenPreventsReupload") { deleteTests.testHydratingPathTokenPreventsReupload() }
    await runTest("DeleteSyncTests.testLocalDirectoryCreationCreatesRemoteDirectory") { try await deleteTests.testLocalDirectoryCreationCreatesRemoteDirectory() }
    await runTest("DeleteSyncTests.testProvenanceTokenPersistsInDatabase") { deleteTests.testProvenanceTokenPersistsInDatabase() }
    await runTest("DeleteSyncTests.testMockAdapterRecursiveDirectoryDelete") { try await deleteTests.testMockAdapterRecursiveDirectoryDelete() }
    await runTest("DeleteSyncTests.testRetrySchedulerProcessesPendingDeletes") { try await deleteTests.testRetrySchedulerProcessesPendingDeletes() }
    try deleteTests.tearDownWithError()

    // AdversarialPathsTests
    let advTests = AdversarialPathsTests()
    try advTests.setUpWithError()
    await runTest("AdversarialPathsTests.testAdversarialFilenamesAndNewlineHandling") { try await advTests.testAdversarialFilenamesAndNewlineHandling() }
    await runTest("AdversarialPathsTests.testSelfInitiatedRemovalTokenLifecycle") { advTests.testSelfInitiatedRemovalTokenLifecycle() }
    try advTests.tearDownWithError()

    // MoveRenameTests
    let renameTests = MoveRenameTests()
    try renameTests.setUpWithError()
    await runTest("MoveRenameTests.testFileMoveIssuesSingleRemoteMoveNotCopyDelete") { try await renameTests.testFileMoveIssuesSingleRemoteMoveNotCopyDelete() }
    await runTest("MoveRenameTests.testDirectoryMoveRekeysAllDescendants") { try await renameTests.testDirectoryMoveRekeysAllDescendants() }
    await runTest("MoveRenameTests.testUnmatchedDepartureDoesNotDeleteRemote") { try await renameTests.testUnmatchedDepartureDoesNotDeleteRemote() }
    await runTest("MoveRenameTests.testSiblingWithLikeMetacharactersSurvivesRekey") { try await renameTests.testSiblingWithLikeMetacharactersSurvivesRekey() }
    await runTest("MoveRenameTests.testRenameThenDeleteInSameBatchDeletes") { try await renameTests.testRenameThenDeleteInSameBatchDeletes() }
    try renameTests.tearDownWithError()

    print("\n🎉 [All Tests Passed] Successfully verified \(passed) tests across all test suites!")
}

try await runAllTests()
