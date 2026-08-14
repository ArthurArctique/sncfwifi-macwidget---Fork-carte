import Foundation
import Combine

/// Modèle de vue exposé au panneau SwiftUI. Purement des données, aucune logique AppKit.

/// État d'un arrêt dans la desserte du train.
enum StopStatus {
    case passed    // Arrêt déjà desservi
    case current   // Prochain arrêt / arrêt en cours
    case upcoming  // Arrêt à venir
}

/// Un arrêt affiché dans la timeline.
struct StopRow: Identifiable {
    let id: String
    let label: String
    /// Heure théorique "HH:mm" (affichée barrée si retard).
    let theoricTime: String
    /// Heure réelle "HH:mm".
    let realTime: String
    let delayMin: Int
    let status: StopStatus
    /// Dénivelé positif cumulé depuis la gare de départ, en mètres. `nil` tant que le profil
    /// altimétrique du trajet n'a pas été obtenu.
    var elevationGainM: Double?
}

/// Une gare proposée dans le sélecteur "Gare d'arrivée".
struct ArrivalOption: Identifiable {
    let id: String
    let label: String
}

/// Instantané de tout ce que le panneau affiche pour un train connecté.
struct TrainViewState {
    var trainNumber: String?
    var destination: String?
    var delayMin: Int
    var delayCause: String

    var stops: [StopRow]
    var globalProgress: Double

    var speedKmh: Int

    /// Dénivelé positif accumulé depuis le départ jusqu'à la position actuelle, en mètres.
    var currentElevationGainM: Double?
    /// Dénivelé positif de l'ensemble du trajet, en mètres.
    var totalElevationGainM: Double?

    var wifiQuality: Int?      // 0…5
    var wifiDevices: Int?

    // Data en Mo
    var dataConsumedMB: Double?
    var dataTotalMB: Double?
    var dataRemainingMB: Double?
    var dataRatio: Double?     // 0…1
    var dataResetTime: String? // "HH:mm"

    var arrivalOptions: [ArrivalOption]
    var selectedArrivalId: String?

    // ── Champs ajoutés pour le multi-opérateur ────────────────────────────────
    // Tous optionnels / avec valeur par défaut : le chemin SNCF les laisse tels quels et n'a
    // donc rien à passer à l'init memberwise.

    /// Opérateur dont proviennent les données (pilote le libellé et la couleur d'accent).
    var operatorKind: TrainOperator = .sncf

    /// Nom de la rame / du système embarqué (Eurostar : `system_name`, ex. "eurostar-blue-main").
    var rameName: String?

    // Détail de la connectivité sol↔train, exposé par la plateforme Icomera uniquement.

    /// `false` si le train a perdu toute liaison montante.
    var isOnline: Bool?
    /// Meilleur RSSI parmi les modems actifs, en dBm.
    var signalRSSI: Int?
    /// Qualité dérivée du RSSI, 0…5 (même échelle que `wifiQuality` côté SNCF).
    var signalQuality: Int?
    /// Technologie du meilleur lien : "5G", "4G", "3G", "2G".
    var linkTechnology: String?
    /// Nombre de modems actifs (les rames en agrègent plusieurs).
    var activeModemCount: Int?
    /// Opérateurs mobiles utilisés, déduits des MCC/MNC (ex. ["Orange", "SFR", "Bouygues"]).
    var modemOperators: [String] = []
    /// Débit descendant maximal autorisé pour la session, en Mbit/s.
    var bandwidthDownMbps: Double?
    /// Temps de session restant, quand la plateforme en impose un.
    var dataTimeLeft: String?
}

/// Mise en forme des volumes de données, partagée entre le panneau et la barre des menus.
///
/// Les deux plateformes n'ont pas les mêmes ordres de grandeur de quota (quelques dizaines de Mo
/// côté SNCF, 1 Go côté Eurostar), d'où la bascule automatique d'unité. Le séparateur décimal
/// suit la locale : virgule en français.
enum DataVolume {
    /// "16,9 Mo", "1,0 Go" — bascule en Go au-delà de 1000 Mo.
    static func label(_ megabytes: Double) -> String {
        if megabytes >= 1000 {
            return String(format: "%.1f Go", locale: .current, megabytes / 1000)
        }
        return String(format: "%.1f Mo", locale: .current, megabytes)
    }

    /// Variante compacte pour la barre des menus : pas de décimale en Mo ("983 Mo", "1,4 Go").
    static func compactLabel(_ megabytes: Double) -> String {
        if megabytes >= 1000 {
            return String(format: "%.1f Go", locale: .current, megabytes / 1000)
        }
        return String(format: "%.0f Mo", locale: .current, megabytes)
    }
}

/// État global du panneau.
enum PanelState {
    case loading
    case notConnected(demoMode: Bool)
    case connected(TrainViewState)
}

/// Source d'observation pour la vue SwiftUI. Le `MenuBarController` pousse l'état
/// et branche les closures d'action (elles appellent les `@objc` existants).
final class TrainStore: ObservableObject {
    @Published var state: PanelState = .loading

    /// Date de la dernière actualisation réussie (pour l'indicateur discret du panneau).
    @Published var lastRefreshDate: Date?
    /// `true` quand la carte occupe le popover à la place du panneau d'informations.
    @Published var showsMap = false
    /// Intervalle entre deux actualisations automatiques (doit refléter le Timer du contrôleur).
    let refreshInterval: TimeInterval = 30

    // Actions branchées par le contrôleur AppKit.
    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSelectArrival: (String) -> Void = { _ in }
    var onToggleDemo: () -> Void = {}
    /// Change l'opérateur simulé en mode démo (le serveur local sert les deux plateformes).
    var onSetDemoOperator: (TrainOperator) -> Void = { _ in }
    var onOpenDemoPanel: () -> Void = {}
    var onCopyJSON: () -> Void = {}
    var onOpenAbout: () -> Void = {}
    /// Appelée quand un réglage de notification change (pour relancer un refresh).
    var onSettingsChanged: () -> Void = {}
}
