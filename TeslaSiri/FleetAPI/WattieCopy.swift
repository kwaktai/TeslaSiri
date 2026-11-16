import Foundation

/// Picks Korean copy when the device language is Korean, and English otherwise.
enum WattieCopy {
    static var prefersKorean: Bool {
        if Locale.preferredLanguages.first?.hasPrefix("ko") == true { return true }
        return Locale.current.identifier.hasPrefix("ko")
    }

    static func text(_ english: String, _ korean: String) -> String {
        prefersKorean ? korean : english
    }
}
