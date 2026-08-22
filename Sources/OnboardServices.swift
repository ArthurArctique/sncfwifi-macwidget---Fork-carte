import AppKit

/// Services à bord annoncés par l'API du train, sous forme de codes SNCF (`OCEWF`, `OCEBA`…).
///
/// Ces codes sont exactement ce qui alimente la rangée d'icônes « Services à bord de ce train »
/// dans SNCF Connect. L'API ne fournit ni libellé ni icône : la correspondance ci-dessous est
/// établie d'après l'usage, et **les codes inconnus sont affichés tels quels** plutôt que devinés.
/// Mieux vaut un code brut à l'écran qu'un pictogramme qui annonce un service inexistant.
struct OnboardService: Identifiable {

    let code: String
    let label: String
    /// Symbole retenu, déjà vérifié comme disponible sur le système courant.
    let symbolName: String

    var id: String { code }

    /// Correspondances retenues. Le second symbole est un repli pour les systèmes antérieurs à
    /// macOS 12, où les pictogrammes de SF Symbols 3 et suivants n'existent pas — `NSImage` les
    /// résout à `nil` sans que le compilateur puisse le signaler.
    private static let known: [String: (label: String, preferred: String, fallback: String)] = [
        "OCEWF": ("Wi-Fi",                  "wifi",                 "wifi"),
        "OCEPP": ("Prises électriques",     "powerplug",            "bolt.fill"),
        "OCECM": ("Climatisation",          "snowflake",            "snowflake"),
        "OCEHP": ("Accès mobilité réduite", "figure.roll",          "accessibility"),
        "OCEBA": ("Bar",                    "cup.and.saucer.fill",  "cup.and.saucer.fill"),
        "OCEWR": ("Restauration",           "fork.knife",           "fork.knife"),
        "OCENY": ("Espace nurserie",        "stroller",             "drop.fill"),
    ]

    /// Construit la liste affichable, en écartant les doublons et en conservant l'ordre de l'API.
    static func list(from codes: [String]) -> [OnboardService] {
        var seen = Set<String>()
        return codes.compactMap { raw in
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !code.isEmpty, seen.insert(code).inserted else { return nil }

            guard let entry = known[code] else {
                // Code non répertorié : on l'affiche sans prétendre savoir ce qu'il désigne.
                return OnboardService(code: code, label: code, symbolName: "questionmark.circle")
            }
            return OnboardService(code: code, label: entry.label, symbolName: resolve(entry))
        }
    }

    private static func resolve(_ entry: (label: String, preferred: String, fallback: String)) -> String {
        NSImage(systemSymbolName: entry.preferred, accessibilityDescription: nil) != nil
            ? entry.preferred
            : entry.fallback
    }
}
