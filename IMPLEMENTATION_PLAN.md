# OpenDuck Implementation Plan

## 1. Product Direction

OpenDuck should become a native macOS SFTP File Provider whose files appear in Finder under `~/Library/CloudStorage`. macOS should own local materialization, eviction, Finder integration, and delivery of filesystem operations. OpenDuck should own remote metadata, SFTP transport, conflict detection, durable operation tracking, and remote-change discovery.

The existing sparse APFS image and FSEvents implementation should not remain the primary writable mount. It cannot intercept reads before an application accesses a placeholder, and it must infer user intent from ambiguous filesystem events. Keep it temporarily as an explicitly labeled **Legacy Preview / Read-Only Mirror** while the File Provider path reaches feature parity, then remove it from the normal product flow.

## Current delivery status

The consolidated final-overhaul PR implements the highest-risk correctness and usability slice of this plan:

- Native File Provider registration is the default profile flow; the sparse-image path is explicitly labeled as a legacy mirror.
- SFTP paths are canonicalized and confined to the configured root.
- File Provider items carry durable content/metadata versions, and stale writes/deletes are recorded as conflicts.
- Downloads use unique staging files with version and byte-count verification before materialization.
- Native working-set signals trigger remote scans and durable change-log enumeration, including offline-journal protection.
- Pending operations and unresolved conflicts are visible in the host UI, with Keep Local/Keep Remote controls and redacted diagnostics export.

The remaining release work is primarily packaging and environment qualification: a canonical signed Xcode project/extension target, App Group entitlements, real Finder integration testing against OpenSSH, and long-running fault-injection tests on multiple macOS versions.

### Initial product scope

Ship one backend well before adding more:

- Supported: SFTP over password or SSH key authentication.
- Supported Finder operations: browse, open/download, create file, create folder, edit/upload, rename, move, duplicate, delete, and remote refresh.
- Supported operating conditions: intermittent connectivity, application/extension restart, transfer cancellation, and concurrent Finder activity.
- Deferred until the SFTP release is dependable: S3, WebDAV, sharing, collaboration, remote search, and advanced POSIX semantics.

### Non-negotiable correctness rules

1. Never acknowledge a Finder mutation until the remote result is committed or durably recoverable.
2. Never overwrite remote content without checking the version on which the local edit was based.
3. Never delete the existing remote file as the first step of an overwrite.
4. Every remote mutation must be idempotent or carry enough persisted state to recover safely.
5. Item identity must remain stable across rename and move operations.
6. A failed or uncertain operation must be visible to the user; it must not become a success message.
7. No cache eviction or OpenDuck-initiated local cleanup may be interpreted as a remote deletion.

## 2. Target Architecture

### Host application

The menu bar app owns:

- Connection/profile configuration.
- File Provider domain registration and removal through `NSFileProviderManager`.
- Keychain enrollment and host-key approval/reset flows.
- Per-domain status, transfer history, conflicts, and recovery controls.
- Preferences, launch-at-login, diagnostics export, and update handling.

The host does not mount disk images or perform the primary synchronization loop.

### File Provider extension

One extension instance serves one registered domain/profile. It owns:

- Establishing and recovering its own SFTP connection.
- Enumeration and change enumeration.
- Content fetching with cancellation and progress.
- Create, modify, rename, reparent, and delete operations.
- Mapping File Provider calls to durable remote operations.
- Signaling remote changes back to Finder.

No live adapter object or other in-memory singleton is shared between the host and extension processes.

### Shared domain store

Use an App Group container with a separate SQLite database per domain. Suggested tables:

- `profiles`: non-secret connection configuration and schema version.
- `items`: stable item ID, parent ID, filename, remote path, type, size, timestamps, permissions, and current content/metadata versions.
- `directory_snapshots`: last observed children and scan timestamp.
- `change_log`: monotonically increasing sequence, changed/deleted item ID, and change type.
- `operations`: durable mutation ledger with state, expected base version, staging path, retry data, and last error.
- `conflicts`: local version, remote version, resolution state, and user-facing explanation.
- `host_keys`: preferably migrated from the existing database or stored in a dedicated shared security store.

Secrets belong in Keychain with a Keychain access group shared by the host and extension. Private-key file access must use a persistent security-scoped bookmark or an imported encrypted key stored in an app-controlled secure location.

### Stable identity and versions

- Domain identifier: profile UUID.
- Item identifier: persistent random UUID stored in `items`; never derive it from a path.
- Parent identity: stored explicitly and returned accurately for every item.
- Remote path: derived from the item hierarchy and cached for efficient SFTP calls.
- Metadata version: changes when name, parent, permissions, type, size, or timestamps change.
- Content version: based on the best available SFTP evidence. Initially use a canonical fingerprint of size, high-resolution modification time when available, and stable attributes. Add optional server-side hashing for conflict verification, not routine enumeration.

## 3. Milestone Plan

### Milestone 0 — Safety Containment and Baseline

Goal: make the current alpha safer while the replacement mount path is built.

### Work

- Make new sparse-image profiles read-only by default.
- Label the current mount path `Legacy Preview / Experimental` in the UI.
- Disable automatic recursive remote folder deletion in legacy mode.
- Disable or clearly reject directory rename in legacy mode instead of allowing silent divergence.
- Stop reporting Sync success when any directory refresh failed.
- Persist the existing upload journal under Application Support and start/stop its retry scheduler with the connection lifecycle.
- Make the Sync button flush pending writes before pulling remote changes.
- Surface journaled and divergence operations in a basic recovery view.
- Replace the SFTP unlink-then-rename overwrite fallback with a non-destructive implementation.
- Remove broad filename ignore rules that can silently skip legitimate files; constrain ignores to OpenDuck-owned staging names and known macOS metadata.
- Add a prominent backup warning to write-enabled legacy profiles.

### Exit criteria

- Legacy mounts default to read-only.
- No code path deletes an existing remote file before a replacement is ready and verified.
- Failed sync operations produce a failed/partial result in the UI.
- Pending operations survive app restart and are visible.

### Milestone 1 — Real App and File Provider Packaging

Goal: establish a correctly signed, debuggable File Provider product shell.

### Work

- Create a canonical Xcode workspace with:
  - `OpenDuckApp` macOS application target.
  - `OpenDuckFileProvider` File Provider Extension target.
  - `OpenDuckCore` retained as a Swift package/library.
  - Unit and integration test targets.
- Use consistent macOS deployment targets across SwiftPM, Info.plists, and Xcode settings.
- Configure Development Team signing, App Sandbox, App Groups, Keychain Sharing, and network-client entitlements for both targets.
- Replace the custom executable-style extension entry point with a genuine File Provider extension target lifecycle.
- Move profile persistence from `UserDefaults.standard` to the shared domain store.
- Register/remove one `NSFileProviderDomain` per profile from the host app using the profile UUID.
- Remove domain registration from the CLI as the normal product workflow; retain diagnostic commands only.
- Add structured `Logger` categories for domain, enumeration, transfer, mutation, database, and connection events.

### Exit criteria

- A mock-backed domain can be added and removed from the GUI.
- Finder displays the domain under CloudStorage.
- The extension reads the correct shared profile after separate host and extension launches.
- Signed development builds survive logout/login and extension restart.

### Milestone 2 — Domain Metadata and SFTP Session Layer

Goal: enumerate a real SFTP tree reliably without file content operations.

### Work

- Convert `SFTPAdapter` into an actor or place it behind a connection actor so client state is serialized.
- Add connection states: disconnected, connecting, connected, degraded, reconnecting, authenticationFailed, hostKeyMismatch.
- Implement exponential reconnect with jitter and explicit cancellation.
- Preserve meaningful SFTP errors; do not translate permission and network failures into file-not-found.
- Define global and per-file request budgets. Avoid multiplying file concurrency by large chunk concurrency on one SFTP channel.
- Add connection keepalive and dead-channel detection.
- Support multiple SFTP channels only after measurement shows one serialized channel is insufficient.
- Populate the `items` table from SFTP listings while preserving stable IDs across refreshes.
- Implement correct root and parent identifiers, file types, sizes, dates, capabilities, and versions.
- Add deterministic pagination for large directories.
- Normalize remote-root joining in one path utility and reject traversal outside the configured root.
- Define symlink behavior for v1: expose safely as links only if File Provider semantics are correct; otherwise report them as unsupported without following them outside the root.

### Exit criteria

- Finder can browse a real SFTP hierarchy containing at least 100,000 items without pre-downloading file contents.
- Empty, inaccessible, missing, and disconnected directories produce distinct correct results.
- Restarting the extension does not change item identifiers.
- Two profiles can operate simultaneously without sharing connection or metadata state.

### Milestone 3 — Correct Read and Materialization Path

Goal: make opening remote files dependable and genuinely on demand.

### Work

- Implement `fetchContents` using a unique local staging file supplied to File Provider only after successful completion.
- Stream downloads with bounded concurrency and responsive cancellation.
- Verify received byte count against remote stat data; optionally hash when a server or policy requests stronger verification.
- Check the requested version before and after transfer. If the remote file changes mid-download, discard the staged result and retry/report a version conflict.
- Return meaningful File Provider errors for offline, not found, permission denied, and unauthenticated states.
- Report download progress to Finder and mirror it into the host's activity view through shared persisted status or a supported IPC mechanism.
- Let File Provider own materialized-item eviction. Remove the separate fake cache accounting for File Provider domains.
- Use `enumeratorForMaterializedItems` or equivalent supported APIs when displaying local cache usage.

### Exit criteria

- Opening a remote file never exposes placeholder zeros or partial data.
- Zero-byte, Unicode-named, package, and multi-gigabyte files download correctly.
- Cancelling, disconnecting, killing the extension, or changing the remote file during download leaves no corrupt visible file.
- No directory listing triggers bulk hydration.

### Milestone 4 — Finder Mutation Matrix

Goal: support all normal Finder write operations with safe commit semantics.

### Common mutation pipeline

For every mutation:

1. Validate the File Provider base version against the current remote version.
2. Persist an operation record and expected outcome.
3. Execute an idempotent remote operation using a unique operation UUID.
4. Verify the remote result.
5. Update item metadata and append a change-log entry transactionally.
6. Complete the File Provider request.
7. Retain enough audit state to explain failures and recover uncertain commits.

### File creation and modification

- Copy incoming content to durable App Group staging when necessary for crash recovery.
- Upload to a unique remote staging name in the destination directory.
- Verify staged size and, when required, hash.
- Prefer the OpenSSH `posix-rename` extension for atomic replacement when supported.
- Implement a safe fallback using a remote backup name and rollback; never unlink the destination first.
- Permit intentional truncation to zero bytes when the request has a valid base version.
- Serialize writes to the same item and coalesce superseded pending content versions.

### Folder creation

- Issue exactly one `mkdir` for the requested path.
- Treat already-existing matching directories idempotently only when the expected identity is known.
- Return filename-collision or permission errors accurately.

### Rename and move

- Use the stable item ID to identify the source; never infer moves by correlating unrelated filesystem events.
- Perform one server-side rename for same-server moves.
- Handle case-only renames through a unique intermediate name when required by the server.
- Update the moved subtree's cached paths transactionally.
- Reject moves outside the configured remote root.

### Delete

- For the first production release, default to a reversible remote trash implemented as a server-side rename into an OpenDuck trash directory on the same filesystem.
- Make permanent deletion an explicit preference with a clear warning.
- Move a directory to trash in one rename rather than recursively unlinking its children.
- Apply circuit-breaker limits to item counts and intent batches, not merely top-level callbacks.
- Never automatically execute operations held by a tripped circuit breaker when the user resets it; show the batch for approval first.

### Exit criteria

- The following all pass from Finder: new file, new empty file, new folder, edit, atomic-save edit, truncate to zero, rename, case-only rename, move across folders, duplicate, trash, and restore/retry.
- Operations remain correct with two simultaneous edits to one item.
- A remote change after the local base version produces a conflict rather than an overwrite.
- Crash injection at every persisted operation state either completes idempotently or stops in a visible recoverable state.

### Milestone 5 — Remote Changes, Offline Behavior, and Conflicts

Goal: converge Finder and SFTP state without losing either side.

### Remote discovery

SFTP has no general push notification mechanism, so use an adaptive scanner:

- Refresh a directory whenever Finder enumerates it and its snapshot is stale.
- Poll recently viewed/materialized directories more frequently.
- Poll inactive directories less frequently with a configurable ceiling.
- Offer a manual full refresh.
- Persist directory snapshots so changes can be detected after extension restart.
- Write detected additions, metadata/content changes, moves when inferable, and deletions to `change_log`.
- Implement real File Provider sync anchors as change-log sequence numbers.
- Call the appropriate File Provider signaling API after remote changes are committed to the log.

Do not claim reliable remote rename detection when SFTP exposes only a disappearance and addition. Preserve stable identity only when evidence is strong; otherwise represent the result as delete plus create.

### Offline and retry behavior

- Distinguish transient transport failure from permanent permission, collision, host-key, and authentication failures.
- Use exponential backoff with jitter per domain.
- Preserve staged local content for recoverable write operations.
- Coalesce repeated modifications to the same file while retaining the newest content and correct base lineage.
- Make delete supersede older pending uploads only after confirming the user's final intent.
- Reconcile uncertain remote commits by inspecting the unique staging/final paths before retrying.

### Conflict policy

- Never silently choose local-wins or remote-wins.
- Preserve both versions for content conflicts.
- Use a deterministic conflict filename containing the device name and timestamp.
- Surface conflicts in both Finder state and the OpenDuck activity UI.
- Provide `Keep Local`, `Keep Remote`, and `Keep Both` actions when resolution cannot be automatic.

### Exit criteria

- Changes made by Cyberduck/SSH become visible in Finder within the documented refresh window.
- Local edits made through transient disconnections eventually upload once, without duplicates.
- Authentication and host-key failures stop retries and request user action.
- No conflict scenario overwrites either version silently.

### Milestone 6 — Product Experience and Operations UI

Goal: make behavior understandable enough for everyday use.

### Work

- Replace the single global status string with per-domain state and an operation/activity model.
- Add an Activity window containing:
  - Active transfers with progress, speed, and cancellation.
  - Pending and retrying operations.
  - Blocked operations requiring action.
  - Conflicts and divergence events.
  - Completed operations with bounded retention.
- Make Retry, Cancel, Resolve, and Reveal/Copy Remote Path actions operate on the exact persisted operation ID.
- Implement auto-connect as domain availability rather than eagerly mounting disk images.
- Wire launch-at-login through `SMAppService`.
- Wire cache settings to supported File Provider materialization/eviction behavior; do not promise a hard cache size if macOS does not expose one.
- Hide S3 and WebDAV until functional, or label them unavailable rather than allowing broken profiles.
- Add connection validation before saving: host, port, credentials, host key, remote root, permissions, and writable-mode probe.
- Require explicit confirmation for profile deletion, host-key replacement, permanent deletion mode, and destructive recovery actions.
- Add a diagnostics export with redacted logs, domain state, schema version, recent errors, and operation history. Never include passwords, private keys, or file contents.

### Exit criteria

- A regular user can tell whether a file is local, transferring, queued, conflicted, failed, or synchronized.
- Every blocked state has a specific actionable next step.
- All visible preferences have real persistence and behavior.
- No unsupported protocol can be configured accidentally.

### Milestone 7 — Verification, Distribution, and Release

Goal: qualify OpenDuck for routine use rather than alpha experimentation.

### Test architecture

- Convert `OpenDuckTests` from an executable target to standard XCTest test targets.
- Keep a fast deterministic mock adapter with fault injection.
- Add model/state-machine tests that generate long operation sequences and compare local metadata, expected remote state, and actual adapter state after every step.
- Add a real OpenSSH integration environment with configurable latency, disconnects, permission failures, disk-full responses, and forced process termination.
- Add macOS File Provider integration tests in clean user accounts or disposable VMs.
- Keep destructive integration tests isolated from all personal servers and production profiles.

### Required scenario suites

- Content sizes: 0 B, 1 B, chunk boundary sizes, 1 GB+, sparse files, and files that grow/shrink during transfer.
- Names: spaces, quotes, glob characters, newlines, leading dots/dashes, Unicode normalization variants, emoji, and case-only differences.
- Operations: all Finder mutation paths, atomic-save patterns from common editors, rapid repeated saves, concurrent rename/edit/delete, and bulk operations.
- Failures: network loss at every transfer/commit phase, SFTP channel EOF, permission changes, remote disk full, host-key change, extension kill, host kill, reboot, and database migration failure.
- Remote races: edit-edit, edit-delete, rename-edit, delete-recreate, and remote change during download/upload.
- Scale: large directories, deep trees, many simultaneous Finder requests, and multiple mounted profiles.

### Release gates

Do not call the product generally usable until all are true:

- Zero open data-loss or silent-corruption defects.
- Zero known operations that report success after partial failure.
- Crash-injection recovery passes at every durable mutation state.
- A 72-hour randomized operation soak completes without metadata divergence.
- At least 10,000 generated mixed operations converge exactly against the reference model.
- Transfers survive repeated disconnect/reconnect cycles without duplicated commits.
- A signed and notarized build passes install, upgrade, logout/login, reboot, and uninstall tests on every supported macOS major version.
- Documentation clearly explains offline behavior, conflicts, remote trash, cache behavior, and the limits of SFTP remote-change detection.

## 4. Suggested Code Organization

Keep protocol-neutral state and transport-specific code separate:

```text
Sources/
  OpenDuckCore/
    Domain/
      DomainProfile.swift
      DomainStore.swift
      SchemaMigrations.swift
    Items/
      ItemIdentity.swift
      ItemMetadata.swift
      ItemVersion.swift
      RemotePath.swift
    Operations/
      OperationRecord.swift
      OperationLedger.swift
      MutationCoordinator.swift
      ConflictResolver.swift
    Changes/
      DirectorySnapshot.swift
      RemoteChangeScanner.swift
      ChangeLog.swift
    Transport/
      RemoteFilesystemAdapter.swift
      SFTP/
        SFTPSession.swift
        SFTPTransferEngine.swift
        SFTPSafeCommit.swift
        SFTPErrorMapper.swift
    Security/
      CredentialStore.swift
      HostKeyStore.swift
  OpenDuckFileProvider/
    FileProviderExtension.swift
    FileProviderEnumerator.swift
    FileProviderItem.swift
    FileProviderErrorMapper.swift
  OpenDuckApp/
    Domains/
    Activity/
    Conflicts/
    Preferences/
    Diagnostics/
```

The legacy `VolumeMountManager` should remain isolated and must not share mutation code with the File Provider path. Delete it after the File Provider release meets the migration gate.

## 5. Delivery Strategy

Build and release in narrow vertical slices:

1. Mock File Provider domain that browses correctly.
2. Real SFTP read-only browsing.
3. Reliable on-demand downloads.
4. File upload and modification.
5. Folder creation, rename, and move.
6. Reversible deletion.
7. Remote refresh and conflict handling.
8. Offline recovery and operational UI.
9. Scale, compatibility, signing, and release hardening.

Each slice should ship to a small test channel only after its exit criteria pass. Avoid implementing S3/WebDAV or further polishing the FSEvents write-back heuristics while these slices are incomplete.

## 6. Definition of “Usable” for the First Stable Release

OpenDuck 1.0 is ready for regular SFTP cloud-mount transfers when a user can leave it running for days, use normal Finder and editor workflows, lose connectivity or restart the Mac, and still answer all of these questions accurately:

- Is my file synchronized?
- If not, is it transferring, queued, conflicted, or failed?
- Is the remote original safe?
- What will retrying or cancelling do?
- Did a remote change arrive, and was either version preserved?

If OpenDuck cannot answer one of those questions, it should conservatively stop the affected mutation and present a recoverable action instead of guessing.
