# 🦆 OpenDuck

> **Native macOS Remote Cloud Filesystem Mounter**  
> An open-source alternative to Mountain Duck for mounting remote filesystems directly into macOS Finder.

---

## ✨ Features

- 🖥️ **Native Finder Integration:** Mounts remote endpoints directly into `/Volumes/<ServerName>` and macOS Finder's **Locations** sidebar with native eject icons.
- ⚡ **Smart Cache & LRU Eviction Engine:** Performs on-demand hydration of remote files with write-back journaling, low-watermark LRU eviction, and file pinning.
- 🔒 **Zero Plaintext Secrets:** Passwords and SSH key passphrases are stored strictly in the macOS Keychain via Apple's `Security.framework`.
- 🌐 **SFTP & Extensible Protocols:** Full SFTP remote adapter support, with extensible protocol architecture for Amazon S3 and WebDAV.
- 🎛️ **Dual Interfaces:**
  - **Menu Bar App:** SwiftUI status-item popover for connection management, cache inspection, and mounting.
  - **CLI Tool (`openduck`):** Fast command-line diagnostic tool and test runner.

---

## 🚀 Quick Start

### 1. Build and Run Tests
```bash
# Run the complete automated test suite
swift test
```

### 2. Use the CLI Tool (`openduck`)
```bash
# Run built-in diagnostic and simulation suite
swift run openduck test

# Run a live test against an SFTP endpoint
swift run openduck test-sftp user@hostname --port 22 --key ~/.ssh/id_ed25519 --path /var/www

# View local cache statistics
swift run openduck cache-stats
```

### 3. Build & Install the Menu Bar App
To compile and assemble the macOS `.app` bundle into `/Applications`:
```bash
chmod +x scripts/build_app.sh
./scripts/build_app.sh
```

---

## 🏗️ Architecture

The codebase is modularized using Swift Package Manager:

```
OpenDuck/
├── Sources/
│   ├── OpenDuckCore/           # Core library (CacheEngine, SFTPAdapter, KeychainHelper, VolumeMountManager)
│   ├── OpenDuckApp/            # SwiftUI Menu Bar desktop application
│   ├── OpenDuckExtension/      # macOS File Provider system extension runtime
│   └── OpenDuckCLI/            # Command-line interface (`openduck`)
├── Tests/
│   └── OpenDuckTests/          # Unit & integration test suites
└── scripts/
    ├── build_app.sh            # Release bundle builder & installer
    ├── App.entitlements        # Host App sandbox & app-group entitlements
    └── Extension.entitlements  # File Provider extension entitlements
```

For full architectural blueprints, see [`openduck_architecture.md`](./openduck_architecture.md).

---

## 📄 License

MIT License. Contributions and issues welcome!

