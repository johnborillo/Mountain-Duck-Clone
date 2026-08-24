# 🦆 OpenDuck

> **Native macOS Remote Cloud Filesystem Mounter**
> An open-source alternative to Mountain Duck for mounting remote SFTP and cloud filesystems directly into macOS Finder with on-demand caching and multi-layered data safety barriers.

> [!WARNING]
> **Alpha Software Notice:** OpenDuck is currently in active development (Alpha). While hardened with multiple safety barriers and provenance tracking, always maintain independent backups of remote data during early trials.

---

## 🛡️ Architecture & Security

OpenDuck mounts remote endpoints into macOS Finder using an in-process, high-performance architecture:

- 🖥️ **Native APFS Sparse Virtual Disks:** High-speed `/Volumes/<ProfileName>` virtual volume mounted into macOS Finder's Locations sidebar with real sparse placeholder sizing and opt-in write access.
- 🚀 **Native Citadel SFTP Engine:** In-process, SwiftNIO SSH multiplexed transport. Zero subprocess shell-outs, zero batch-script injection risk, and full support for encrypted Ed25519/RSA SSH private keys and passwords.
- 🔑 **Trust-On-First-Use (TOFU) Key Pinning:** Strict SHA-256 host key fingerprints stored in an isolated database and validated on every connection against OpenSSH `ssh-keygen -lf` standard format to prevent Man-In-The-Middle (MITM) attacks.
- 🗄️ **Persistent SQLite WAL Engine:** Transactional metadata database (`MetadataDatabase.sqlite`) tracking placeholder, materialized, dirty, and uploading states across restarts and crashes.
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
# Run the complete Swift Testing suite
swift test

# Run the 56-assertion CLI automated diagnostic suite
swift run openduck test
```

### 2. Build & Install the Menu Bar App

To compile and assemble the application into `/Applications`:

```bash
swift build -c release
mkdir -p /Applications/OpenDuck.app/Contents/MacOS /Applications/OpenDuck.app/Contents/Resources
cp .build/release/OpenDuckApp /Applications/OpenDuck.app/Contents/MacOS/OpenDuck
chmod +x /Applications/OpenDuck.app/Contents/MacOS/OpenDuck
```

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
