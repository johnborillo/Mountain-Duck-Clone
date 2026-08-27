# 🦆 OpenDuck

> **Native macOS Remote Cloud Filesystem Mounter**
> An open-source alternative to Mountain Duck for mounting remote SFTP and cloud filesystems directly into macOS Finder with on-demand caching and multi-layered data safety barriers.

> [!WARNING]
> **Alpha Software Notice:** OpenDuck is currently in active development (Alpha). While hardened with multiple safety barriers and provenance tracking, always maintain independent backups of remote data during early trials.

---

## 🛡️ Architecture & Security

OpenDuck presents remote endpoints in Finder through the native replicated File Provider architecture:

- 🗂️ **Native File Provider domains:** Each profile has a stable UUID-backed domain under Finder's Cloud Storage locations. Finder owns placeholders, materialization, and eviction; OpenDuck owns remote state and mutations.
- 🦆 **One Finder workflow:** The menu-bar app only registers native Finder domains. The experimental sparse-image `/Volumes` mirror remains internal test code and cannot be mistaken for a production mount.
- 🚀 **Native Citadel SFTP Engine:** In-process, SwiftNIO SSH multiplexed transport. Zero subprocess shell-outs, zero batch-script injection risk, and full support for encrypted Ed25519/RSA SSH private keys and passwords.
- 🔑 **Persistent sandbox-safe authentication:** Passwords and passphrases use a shared Keychain access group. SSH key files remain in place and are reopened by the File Provider extension through a read-only security-scoped bookmark.
- 🔑 **Trust-On-First-Use (TOFU) Key Pinning:** Strict SHA-256 host key fingerprints stored in an isolated database and validated on every connection against OpenSSH `ssh-keygen -lf` standard format to prevent Man-In-The-Middle (MITM) attacks.
- 🗄️ **Persistent SQLite WAL Engine:** Transactional metadata database (`MetadataDatabase.sqlite`) tracking placeholder, materialized, dirty, and uploading states across restarts and crashes.
- 🧭 **Root confinement and stable versions:** Remote paths are canonicalized and rejected when they escape the configured root. File Provider versions use remote fingerprints so stale Finder edits become visible conflicts instead of silent overwrites.
- ✅ **Verified transfer pipeline:** Downloads land in unique staging files, verify the remote version and byte count, then become visible atomically. Uploads use unique remote staging names and atomic replacement.
- 🔄 **Adaptive remote refresh:** Low-frequency working-set signals trigger SFTP scans and durable change-log enumeration so edits made from another client converge in Finder.
- 🧰 **Recovery and diagnostics:** Pending operations, conflicts, retry state, and a redacted JSON diagnostics export are visible from the menu-bar app.
- 🛡️ **6-Layer Anti-Corruption Shield:**
  1. *Extended Attributes (`com.openduck.placeholder`)* for native macOS Finder integration.
  2. *POSIX Read-Only Locking (`0o555`)* causing Finder to enforce write-locks natively on read-only mounts.
  3. *Self-Removal Provenance Suppression* preventing local evictions or teardowns from triggering remote deletes.
  4. *Atomic Remote Staging (`.staging_<uuid>` + `rename`)* ensuring zero partial or corrupted file writes.
  5. *Zero-Byte Overwrite Barrier* preventing placeholder stubs from wiping remote files.
  6. *Dual-Window Mass Deletion Circuit Breaker* halting automated operations if $>10$ deletions/sec (burst) or $>50$ deletions/60sec (sustained) occur.
- 💾 **Decoupled LRU Cache Engine:** Cache storage resides strictly outside `/Volumes/` to prevent local evictions from emitting FSEvents deletes, with automatic write-back preservation for unuploaded dirty edits.
- 🔒 **Zero Plaintext Secrets:** Passwords and SSH key passphrases are stored in macOS Keychain via `Security.framework`.

---

## 🚀 Quick Start

### Requirements
- **macOS 14.0+ (Sonoma or Sequoia)**
- **Swift 6.0+ / Xcode 16+ or Command Line Tools**

### 1. Build and Run Diagnostics

```bash
# Build all products
swift build

# Run the complete deterministic Swift suite
.build/arm64-apple-macosx/debug/OpenDuckTests

# Run the CLI integration/diagnostic suite
swift run openduck test
```

### 2. Build & Install the Menu Bar App

To compile, assemble, sign ad hoc, and install the app plus File Provider extension into `/Applications`:

```bash
./scripts/build_app.sh
```

The current distribution script is development-oriented and defaults to ad-hoc signing. Ad-hoc builds cannot carry the restricted shared-Keychain entitlement, so password authentication and encrypted-key passphrases are only available to Finder in a correctly provisioned team-signed build; an unencrypted SSH key selected with **Browse** remains suitable for local development. Set `OPENDUCK_SIGNING_IDENTITY` to a valid signing identity when using matching App Group and Keychain provisioning. A distributable release still needs a canonical Xcode project, provisioning, hardened runtime, notarization, and release signing.

After upgrading from an earlier build, OpenDuck automatically recreates only its broken local Finder domain records; remote SFTP data and the durable OpenDuck operation journal are not deleted. Existing SSH-key profiles must be edited once so the key can be selected with **Browse** and macOS can issue persistent read permission to the extension.

---

## 🏗️ Repository Layout

```
OpenDuck/
├── Sources/
│   ├── OpenDuckCore/           # Core library (CacheEngine, Citadel SFTPAdapter, MetadataDatabase, VolumeMountManager)
│   ├── OpenDuckApp/            # SwiftUI Menu Bar desktop application
│   ├── OpenDuckExtension/      # File Provider scaffolding (Target Architecture 2.0)
│   └── OpenDuckCLI/            # Command-line diagnostics and test runner (`openduck`)
├── Tests/
│   └── OpenDuckTests/          # Swift Testing unit & integration test suites
```

---

## 📄 License

MIT License. Contributions and issues welcome!
