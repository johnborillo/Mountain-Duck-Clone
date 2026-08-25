import Foundation

/// Canonical remote POSIX path operations shared by every integration boundary.
/// Keeping this logic in one place prevents a stale File Provider identifier or a
/// malformed Finder filename from escaping the configured SFTP root.
public enum RemotePath {
    public static func normalize(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var result: [Substring] = []
        for component in components {
            switch component {
            case ".": continue
            case "..":
                if !result.isEmpty { result.removeLast() }
            default: result.append(component)
            }
        }
        return result.isEmpty ? "/" : "/" + result.joined(separator: "/")
    }

    public static func join(_ parent: String, _ child: String) -> String {
        let normalizedParent = normalize(parent)
        let cleanChild = child.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanChild.isEmpty else { return normalizedParent }
        return normalize(normalizedParent + "/" + cleanChild)
    }

    public static func isWithin(_ path: String, root: String) -> Bool {
        let normalizedPath = normalize(path)
        let normalizedRoot = normalize(root)
        return normalizedRoot == "/"
            || normalizedPath == normalizedRoot
            || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    public static func relativePath(of path: String, from root: String) -> String? {
        guard isWithin(path, root: root) else { return nil }
        let normalizedPath = normalize(path)
        let normalizedRoot = normalize(root)
        if normalizedRoot == "/" { return String(normalizedPath.dropFirst()) }
        guard normalizedPath != normalizedRoot else { return "" }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }
}
