# 🦆 OpenDuck

> **Native macOS Remote Cloud Filesystem Mounter**
> An open-source alternative to Mountain Duck for mounting remote filesystems directly into macOS Finder.

> [!WARNING]
> **Alpha Software Notice:** OpenDuck is currently in active development (Alpha). While hardened with multiple safety barriers, do not point it at irreplaceable production data without current backups.

---

## 🛡️ Architecture & Security

OpenDuck mounts remote endpoints into macOS Finder using an in-process, high-performance architecture:

- 🖥️ **Native APFS Sparse Virtual Disks:** High-speed `/Volumes/<ProfileName>` virtual volume mounted into macOS Finder's Locations sidebar with real sparse placeholder sizing.
- 🚀 **Native Citadel SFTP Engine:** In-process, SwiftNIO SSH multiplexed transport. Zero shell-outs, zero batch-script injection risk, and full support for encrypted Ed25519/RSA SSH keys and passwords.
- 🔑 **Trust-On-First-Use (TOFU) Key Pinning:** SHA-256 host key fingerprints are verified on every connection to prevent Man-In-The-Middle (MITM) attacks.
- 🗄️ **Persistent SQLite WAL Engine:** Transactional metadata database (`MetadataDatabase.sqlite`) tracking placeholder, materialized, dirty, and uploading states across restarts and crashes.
- 🛡️ **6-Layer Anti-Corruption Shield:**
  1. *Extended Attributes (`com.openduck.placeholder`)* for macOS integration.
  2. *POSIX Read-Only Locking (`0o555`)* causing Finder to enforce write-locks natively.
  3. *Self-Removal Provenance Suppression* preventing local evictions or teardowns from triggering remote deletes.
  4. *Atomic Remote Staging (`.staging_<uuid>` + `rename`)* ensuring zero partial or corrupted file writes.
  5. *Zero-Byte Overwrite Barrier* preventing placeholder stubs from wiping remote files.
  6. *Mass Deletion Circuit Breaker* halting automated operations if $>10$ deletions occur per second.
- 🔒 **Zero Plaintext Secrets:** Passwords and SSH key passphrases are stored in macOS Keychain via `Security.framework`.

---

## 🚀 Quick Start

### Requirements
- **macOS 14.0+ (Sonoma or Sequoia)**
- **Swift 5.9+ / Xcode 15+**

### 1. Build and Run Diagnostics

```bash
# Run the complete 42-assertion automated test suite
swift run openduck test
```

### 2. Build & Install the Menu Bar App

To compile and assemble the optimized release application into `/Applications`:

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
│   └── OpenDuckTests/          # Unit & integration test suites
```

---

## 📄 License

MIT License. Contributions and issues welcome!
