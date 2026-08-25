# 🦆 OpenDuck

> **Native macOS Remote Cloud Filesystem Mounter**
> An open-source alternative to Mountain Duck for mounting remote SFTP and cloud filesystems directly into macOS Finder with on-demand caching and multi-layered data safety barriers.

> [!WARNING]
> **Alpha Software Notice:** OpenDuck is currently in active development (Alpha). While hardened with multiple safety barriers and provenance tracking, always maintain independent backups of remote data during early trials.

---

## 🛡️ Architecture & Security

OpenDuck presents remote endpoints in Finder using the native File Provider path first. The older sparse-image mirror remains available as an explicitly labeled compatibility mode while the native domain matures:

- 🗂️ **Native File Provider domains:** Each profile has a stable UUID-backed domain under Finder's Cloud Storage locations. Finder owns placeholders, materialization, and eviction; OpenDuck owns remote state and mutations.
- 🖥️ **Legacy Preview / Mirror:** The APFS sparse-image path is retained for compatibility and diagnostics, but is no longer the default connection flow and is clearly labeled in the menu bar.
- 🚀 **Native Citadel SFTP Engine:** In-process, SwiftNIO SSH multiplexed transport. Zero subprocess shell-outs, zero batch-script injection risk, and full support for encrypted Ed25519/RSA SSH private keys and passwords.
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

The current distribution script is intentionally development-oriented (ad-hoc signing and a generated bundle). A notarized release still needs a canonical Xcode project, team signing, App Groups, and production entitlements.

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
