import Foundation

enum L {
    static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    static func f(_ key: String, _ values: String...) -> String {
        String(format: t(key), locale: .current, arguments: values)
    }
}
