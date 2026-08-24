# Walkthrough: OpenDuck 6-Layer Defensive Safeguard & Hardened Sync Engine

### 🛡️ Defensive Architecture Overview

OpenDuck features a **6-Layer Defensive Architecture** and native **Citadel (SwiftNIO SSH)** in-process transport to eliminate data loss, command injection, and inferred deletion risks.

---

### 🧱 The 6 Layers of Defense

```
                       [ Local File Event Detected ]
                                     │
   [ Layer 1: SQLite State ]        ─► Is record in 'placeholder' or 'uploading' state?
                                     │ └── YES ──► 🛑 IGNORED. Never upload placeholder stubs.
                                     ▼ NO
   [ Layer 2: POSIX Read-Only Lock ]─► Is volume mounted in Read-Only mode?
                                     │ └── YES ──► 🛑 BLOCKED. Enforced natively with 0o555 permissions.
                                     ▼ NO
   [ Layer 3: Delete Provenance ]   ─► Is file removal in 'selfInitiatedRemovals' set?
                                     │ └── YES ──► 🛑 REFUSED. Local eviction/unmount never deletes remote.
                                     ▼ NO
   [ Layer 4: Zero-Byte Guard ]     ─► Is local size == 0 bytes?
                                     │ └── YES ──► 🛑 IGNORED. 0-byte stubs never auto-upload.
                                     ▼ NO
   [ Layer 5: Atomic Staging ]      ─► Upload to ".filename.openduck_staging_UUID" via Citadel
                                     │ Verify 100% byte integrity & packet completion
                                     ▼ SUCCESS
                                      Atomic SFTP Rename -> "filename"
                                     ▼
   [ Layer 6: Circuit Breaker ]     ─► Deletions exceeding 10 files/sec?
                                       └── YES ──► 🛑 HALT. Log divergence event & pause operations.
```

---

### 📂 Structural Hardening Summary

1. **`Sources/OpenDuckCore/Adapters/SFTP/SFTPAdapter.swift`:**
   * **In-Process Citadel Engine:** Directly executes binary SFTP RPC packets via SwiftNIO SSH. Eliminates shell execution (`/usr/bin/sftp`), batch-file command injection, and option injection.
   * **Trust-On-First-Use (TOFU) Pinning:** Computes SHA-256 host key fingerprints (`OpenDuckHostKeyValidator.swift`) and persists them to SQLite. Prevents MITM attacks.
   * **In-Process Auth:** Full support for passwords and passphrase-encrypted Ed25519 and RSA private keys without requiring interactive `/dev/tty`.
   * **Atomic Staging & Verified Rename:** Writes to temporary staging files (`.<filename>.openduck_staging_<uuid>`) and renames upon 100% verified completion.

2. **`Sources/OpenDuckCore/Mount/VolumeMountManager.swift`:**
   * **Self-Removal Provenance Suppression:** OpenDuck-initiated local deletions (cache eviction, remote reconciliation) are registered before deletion. FSEvents intercepts and refuses remote deletion.
   * **Watcher Invalidation on Unmount:** Detaching or unmounting invalidates event streams *before* unmounting the APFS image.
   * **Single Authoritative State:** `MetadataDatabase.shared` is the sole source of truth for file states (`placeholder`, `hydrating`, `materialized`, `dirty`, `uploading`).

3. **`Sources/OpenDuckCore/Database/MetadataDatabase.swift`:**
   * **ACID SQLite Storage:** Backed by Apple `libsqlite3` with Write-Ahead Logging (WAL) for high concurrency and crash resilience.
   * **Host Key & Divergence Tracking:** Persists pinned host keys and logs divergence events when the circuit breaker trips.

4. **Automated Verification:**
   * **42 automated test assertions** pass across 7 comprehensive test suites (`swift run openduck test`).
