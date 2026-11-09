import Foundation

/// A task may use a chosen symbol or one user-entered grapheme, including a composed emoji.
public enum TaskIcon: Codable, Equatable, Sendable {
    case symbol(String)
    case character(String)

    public var isValid: Bool {
        switch self {
        case .symbol(let name):
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.")
            return !name.isEmpty && name.utf8.count <= 80 && name.unicodeScalars.allSatisfy(allowed.contains)
        case .character(let text):
            let visible = CharacterSet.alphanumerics.union(.symbols).union(.punctuationCharacters)
            return text.count == 1 && text.utf8.count <= 64
                && text.unicodeScalars.contains(where: visible.contains)
                && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }
}
