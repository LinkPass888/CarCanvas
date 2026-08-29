import Foundation

/// All user-visible copy lives in Localizable.strings under three .lproj
/// bundles. Keys are intentionally stable identifiers (never English text)
/// so that en / ja / zh-Hans stay aligned.
@inlinable
func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

/// Formatted variant. Placeholder order is validated by
/// scripts/verify-repository.py against the English strings file.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
