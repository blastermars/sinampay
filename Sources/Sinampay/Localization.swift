import Foundation

private enum Language { case english, filipino, spanish }

private let language: Language = {
    let first = Locale.preferredLanguages.first?.lowercased() ?? ""
    if first.hasPrefix("fil") || first.hasPrefix("tl") { return .filipino }
    if first.hasPrefix("es") { return .spanish }
    return .english
}()

/// Tiny three-language helper: English, Filipino and Spanish. The app has a
/// handful of strings, so a full .strings setup would be more ceremony than
/// content.
func L(_ english: String, fil: String, es: String) -> String {
    switch language {
    case .english: english
    case .filipino: fil
    case .spanish: es
    }
}
