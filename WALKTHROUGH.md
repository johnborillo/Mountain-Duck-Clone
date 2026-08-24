# Walkthrough: OpenMountainDuck Native `/Volumes` Integration & Deep Recursive Sync

### 🔍 Diagnostic: Subfolder Emptiness & Container Path
1. **Empty Subfolders:** Previously, the mount routine only executed a shallow single-level `listDirectory("/")`. Any detected directory (like `data-storage`) was created locally as a folder shell, but its child items were not fetched.
2. **`~/Library/Containers/...` Path:** macOS App Sandbox isolation was automatically redirecting file access into the app's internal container directory instead of a system-wide volume.

---

### 🔧 Architecture Upgrade: Native `/Volumes` & Deep Sync Engine

1. **Native `/Volumes` Mount Point ([`VolumeMountManager.swift`](file:///Users/johnborillo/Documents/Mountain%20Duck%20Clone/Sources/OpenMountainDuckCore/Mount/VolumeMountManager.swift)):**
   * Uses native macOS virtual volume mounting at `/Volumes/<ProfileName>`.
   * **Finder Locations Integration:** macOS automatically registers `/Volumes/<ProfileName>` directly under the **Locations** section in the Finder sidebar (alongside your Macintosh HD and network drives) with an unmount/eject icon.
2. **Recursive Tree Synchronization (`syncTree`):**
   * Automatically recurses into subdirectories (such as `data-storage` and nested folders).
   * Populates all child files and folder structures so opening any subfolder in Finder displays its actual contents.
3. **Smart Volume Lifecycle:**
   * Clicking **Mount** attaches `/Volumes/<ProfileName>` and begins recursive synchronization with live status updates.
   * Clicking **Unmount** cleanly detaches the volume from `/Volumes/` and Finder Locations.
   * Clicking **Open in Finder** reveals `/Volumes/<ProfileName>`.
