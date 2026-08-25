import Foundation
import FileProvider
import OpenDuckCore

// Entry point for the FileProvider app extension runtime
@main
struct OpenDuckExtensionMain {
    static func main() {
        // File Provider app extensions enter through Foundation's
        // `_NSExtensionMain` linker entry point (configured on the target).
        // This Swift main is intentionally empty; Launch Services never
        // invokes it for the extension process.
    }
}
