import Foundation

/// Traduit les payloads de la plateforme Icomera (Eurostar) en `TrainViewState`.
///
/// Fonction pure : aucun accès à l'UI ni aux réglages, pour rester testable et ne pas alourdir
/// `MenuBarController`. Toutes les valeurs arrivent sous forme de chaînes côté ombord, d'où
/// l'usage systématique des conversions de `ValueCoercion`.
enum EurostarStateBuilder {

    /// `true` si les payloads contiennent assez d'informations pour considérer qu'on est à bord.
    static func hasUsableData(connectivity: [String: Any]?,
                              position: [String: Any]?,
                              user: [String: Any]?) -> Bool {
        connectivity != nil || position != nil || user != nil
    }

    static func build(system: [String: Any]?,
                      connectivity: [String: Any]?,
                      users: [String: Any]?,
                      user: [String: Any]?,
                      position: [String: Any]?) -> TrainViewState {

        // `speed` est en m/s (comme l'API SNCF), `altitude` en mètres.
        let speed = speedKmh(fromMetersPerSecond: position?["speed"])

        let links = (connectivity?["links"] as? [[String: Any]]) ?? []
        let uplinks = activeUplinks(in: links)
        let isOnline = asBool(connectivity?["online"])

        // Le quota est exprimé en octets (l'API SNCF, elle, renvoie des kB).
        let consumedMB = asDouble(user?["data_total_used"]).map { $0 / 1_000_000 }
        let totalMB = asDouble(user?["data_total_limit"]).flatMap { $0 > 0 ? $0 / 1_000_000 : nil }

        var remainingMB: Double?
        var ratio: Double?
        if let consumedMB, let totalMB, totalMB > 0 {
            remainingMB = max(0, totalMB - consumedMB)
            ratio = max(0, min(1, consumedMB / totalMB))
        }

        // `bandwidth_download_limit` est un débit en octets/s (12 500 000 → 100 Mbit/s).
        let bandwidthMbps = asDouble(user?["bandwidth_download_limit"])
            .flatMap { $0 > 0 ? $0 * 8 / 1_000_000 : nil }

        var state = TrainViewState(
            trainNumber: nil,          // non exposé par la plateforme Icomera
            destination: nil,          // idem
            delayMin: 0,
            delayCause: "",
            stops: [],                 // pas de desserte → timeline masquée par le panneau
            globalProgress: ratio ?? 0.0,
            speedKmh: speed,
            wifiQuality: nil,          // la qualité radio est affichée par la section connectivité
            wifiDevices: asInt(users?["online"]),
            dataConsumedMB: consumedMB,
            dataTotalMB: totalMB,
            dataRemainingMB: remainingMB,
            dataRatio: ratio,
            dataResetTime: nil,        // `expires` vaut "Never" : pas de remise à zéro périodique
            arrivalOptions: [],        // pas de gares → sélecteur masqué
            selectedArrivalId: nil
        )

        state.operatorKind = .eurostar
        state.rameName = asNonEmptyString(system?["system_name"])
        state.isOnline = isOnline
        // `nil` si l'endpoint connectivité n'a pas répondu : la section reste masquée plutôt que
        // d'annoncer « 0 modem », ce qui serait faux.
        state.activeModemCount = connectivity != nil ? uplinks.count : nil
        state.bandwidthDownMbps = bandwidthMbps
        state.dataTimeLeft = timeLeftLabel(user?["timeleft"])

        if let best = uplinks.max(by: { $0.rssi < $1.rssi }) {
            state.signalRSSI = best.rssi
            // Hors ligne, le RSSI n'a plus de sens pour l'utilisateur : on affiche 0 barre.
            state.signalQuality = (isOnline == false) ? 0 : quality(forRSSI: best.rssi)
        } else if isOnline == false {
            state.signalQuality = 0
        }

        state.linkTechnology = uplinks
            .compactMap { $0.technology }
            .max(by: { technologyRank($0) < technologyRank($1) })

        // Dédoublonnage en conservant l'ordre : plusieurs modems peuvent partager un opérateur.
        var seenOperators = Set<String>()
        state.modemOperators = uplinks.compactMap { $0.operatorName }.filter { seenOperators.insert($0).inserted }

        return state
    }

    // MARK: - Liens montants

    /// Un modem exploitable : allumé, lien disponible et RSSI renseigné.
    struct Uplink {
        let rssi: Int
        let technology: String?
        let operatorName: String?
    }

    private static func activeUplinks(in links: [[String: Any]]) -> [Uplink] {
        links.compactMap { link -> Uplink? in
            guard (link["device_type"] as? String) == "modem",
                  (link["device_state"] as? String) == "up",
                  (link["link_state"] as? String) == "available"
            else { return nil }

            // `-1` est la valeur sentinelle d'ombord pour « non renseigné ».
            guard let rssi = asInt(link["rssi"]), rssi < 0, rssi != -1 else { return nil }

            return Uplink(rssi: rssi,
                          technology: technologyLabel(link["technology"]),
                          operatorName: operatorName(forMobileCode: link["operator_id"]))
        }
    }

    // MARK: - Signal

    /// RSSI (dBm) → 0…5, même échelle que l'indicateur SNCF.
    static func quality(forRSSI rssi: Int) -> Int {
        switch rssi {
        case (-65)...:      return 5
        case (-75)...(-66): return 4
        case (-85)...(-76): return 3
        case (-95)...(-86): return 2
        case (-105)...(-96): return 1
        default:            return 0
        }
    }

    // MARK: - Technologie

    /// Normalise les valeurs d'ombord en génération réseau lisible.
    /// `endc` = E-UTRAN New Radio Dual Connectivity, c'est-à-dire de la 5G non-standalone.
    static func technologyLabel(_ value: Any?) -> String? {
        guard let raw = asNonEmptyString(value)?.lowercased(), raw != "-1" else { return nil }
        switch raw {
        case "endc", "nr", "5g", "nsa", "sa":            return "5G"
        case "lte", "lte-a", "lte_ca", "4g":             return "4G"
        case "umts", "hsdpa", "hsupa", "hspa", "hspa+", "wcdma", "3g":
                                                         return "3G"
        case "gsm", "edge", "gprs", "2g":                return "2G"
        default:                                         return raw.uppercased()
        }
    }

    /// Ordonne les générations pour choisir le meilleur lien.
    private static func technologyRank(_ label: String) -> Int {
        switch label {
        case "5G": return 4
        case "4G": return 3
        case "3G": return 2
        case "2G": return 1
        default:   return 0
        }
    }

    // MARK: - Opérateurs mobiles

    /// MCC+MNC → nom commercial, limité aux pays traversés par Eurostar.
    /// Repli sur `MCC-MNC` pour rester informatif face à un réseau non répertorié.
    static func operatorName(forMobileCode value: Any?) -> String? {
        guard let code = asNonEmptyString(value), code != "-1", code.count >= 5 else { return nil }

        if let name = mobileNetworks[code] { return name }

        let mcc = String(code.prefix(3))
        let mnc = String(code.dropFirst(3))
        return "\(mcc)-\(mnc)"
    }

    private static let mobileNetworks: [String: String] = [
        // France (208)
        "20801": "Orange", "20802": "Orange",
        "20810": "SFR", "20813": "SFR",
        "20815": "Free", "20816": "Free",
        "20820": "Bouygues", "20821": "Bouygues", "20888": "Bouygues",
        // Royaume-Uni (234)
        "23402": "O2", "23410": "O2",
        "23415": "Vodafone UK",
        "23420": "Three",
        "23430": "EE", "23433": "EE", "23486": "EE",
        // Belgique (206)
        "20601": "Proximus",
        "20610": "Orange BE",
        "20620": "BASE",
        // Pays-Bas (204)
        "20402": "Odido", "20416": "Odido", "20420": "Odido",
        "20404": "Vodafone NL",
        "20408": "KPN",
        // Allemagne (262)
        "26201": "Telekom",
        "26202": "Vodafone DE",
        "26203": "O2 DE", "26207": "O2 DE",
    ]

    // MARK: - Session

    /// `timeleft` est un nombre de secondes ; la plateforme renvoie `""` en accès illimité.
    static func timeLeftLabel(_ value: Any?) -> String? {
        guard let seconds = asInt(value), seconds > 0 else { return nil }
        let minutes = seconds / 60
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h) h \(m) min" : "\(h) h"
        }
        return "\(max(1, minutes)) min"
    }
}
