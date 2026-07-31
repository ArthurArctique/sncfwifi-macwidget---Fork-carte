import Foundation

/// Conversions sûres depuis les dictionnaires JSON non typés renvoyés par les API embarquées.
/// Les deux plateformes (SNCF et Icomera/ombord) mélangent nombres et chaînes pour les mêmes
/// champs — l'API Eurostar renvoie même *tout* en chaînes ("speed":"62.244").

func safeInt(_ value: Any?) -> Int {
    guard let value else { return 0 }
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String, let d = Double(s) { return Int(d) }
    return 0
}

func asDouble(_ value: Any?) -> Double? {
    guard let value else { return nil }
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String    { return Double(s) }
    return nil
}

func asInt(_ value: Any?) -> Int? {
    guard let value else { return nil }
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String, let d = Double(s) { return Int(d) }
    return nil
}

func asBool(_ value: Any?) -> Bool? {
    guard let value else { return nil }
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.intValue != 0 }
    if let s = value as? String {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "oui":
            return true
        case "false", "0", "no", "non":
            return false
        default:
            return nil
        }
    }
    return nil
}

/// Vitesse en km/h depuis une valeur en m/s (l'unité des deux plateformes embarquées).
///
/// La conversion est bornée : `Int(_:)` sur un `Double` infini ou NaN provoque une erreur fatale,
/// et une valeur aberrante lue dans le JSON suffirait à faire tomber l'app.
func speedKmh(fromMetersPerSecond value: Any?) -> Int {
    guard let metersPerSecond = asDouble(value),
          metersPerSecond.isFinite,
          metersPerSecond > 0
    else { return 0 }
    return Int(min(metersPerSecond * 3.6, 1000))
}

/// Chaîne non vide, ou `nil`. Utile car ombord renvoie `""` plutôt que d'omettre un champ.
func asNonEmptyString(_ value: Any?) -> String? {
    guard let value else { return nil }
    let string: String
    if let s = value as? String {
        string = s
    } else if let n = value as? NSNumber {
        string = n.stringValue
    } else {
        return nil
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
