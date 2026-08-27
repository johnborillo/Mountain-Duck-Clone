import Foundation
import FileProvider

/// File Provider callbacks may return only Cocoa or File Provider errors.
/// Passing backend-specific Swift errors makes fileproviderd throttle the
/// extension and replaces the useful failure with "Provider returned unsupported
/// error." Preserve the original error as the underlying diagnostic instead.
public enum FileProviderErrorMapper {
    public static func map(_ error: Error) -> Error {
        let original = error as NSError
        if original.domain == NSFileProviderErrorDomain || original.domain == NSCocoaErrorDomain {
            return error
        }

        let code: Int
        if let adapterError = error as? AdapterError {
            switch adapterError {
            case .authenticationFailed:
                code = NSFileProviderError.notAuthenticated.rawValue
            case .notConnected, .networkError, .serverError:
                code = NSFileProviderError.serverUnreachable.rawValue
            case .fileNotFound:
                code = NSFileProviderError.noSuchItem.rawValue
            case .alreadyExists:
                code = NSFileProviderError.filenameCollision.rawValue
            case .permissionDenied, .conflict, .invalidPath, .unsupportedOperation:
                code = NSFileProviderError.cannotSynchronize.rawValue
            }
        } else {
            code = NSFileProviderError.cannotSynchronize.rawValue
        }

        return NSError(
            domain: NSFileProviderErrorDomain,
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: original.localizedDescription,
                NSUnderlyingErrorKey: original
            ]
        )
    }
}
