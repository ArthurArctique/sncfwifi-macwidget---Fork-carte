import Foundation

/// Opérateur ferroviaire dont on sait lire le WiFi embarqué.
///
/// Chaque opérateur expose une plateforme différente : SNCF sert son propre routeur sur
/// `wifi.sncf`, Eurostar utilise la plateforme Icomera sur `ombord.info`. Les données
/// disponibles ne se recoupent que partiellement (cf. `TrainViewState`).
enum TrainOperator: String, CaseIterable {
    case sncf
    case eurostar

    /// Libellé affiché en tête du panneau.
    var displayName: String {
        switch self {
        case .sncf:     return "TGV INOUI"
        case .eurostar: return "Eurostar"
        }
    }

    /// SSID connus, tels qu'annoncés à bord.
    var ssids: [String] {
        switch self {
        case .sncf:
            return ["_SNCF_WIFI_INOUI", "OUIFI", "SNCF_WIFI_INTERCITES", "WIFI_SNCF", "_WIFI_LYRIA"]
        case .eurostar:
            return ["EurostarTrainsWiFi"]
        }
    }

    /// Opérateur correspondant à un SSID, `nil` si le réseau n'est pas un WiFi de train connu.
    /// La comparaison est insensible à la casse : les bornes ne sont pas toujours cohérentes.
    static func matching(ssid: String) -> TrainOperator? {
        guard !ssid.isEmpty else { return nil }
        return allCases.first { op in
            op.ssids.contains { $0.compare(ssid, options: .caseInsensitive) == .orderedSame }
        }
    }
}
