import Foundation

/// Appelle les endpoints de l'API WiFi SNCF en parallèle.
final class TrainAPIClient {
    private let gpsURL        = URL(string: "https://wifi.sncf/router/api/train/gps")!
    // L'endpoint s'appelle `progress` (ou `details`) selon les rames, on laisse les deux pour être sûr mais on priorisera progress.
    private let progressURL   = URL(string: "https://wifi.sncf/router/api/train/progress")!
    private let detailsURL    = URL(string: "https://wifi.sncf/router/api/train/details")!
    private let barURL        = URL(string: "https://wifi.sncf/router/api/bar/attendance")!
    private let statsURL      = URL(string: "https://wifi.sncf/router/api/connection/statistics")!
    private let statusURL     = URL(string: "https://wifi.sncf/router/api/connection/status")!
    private let graphURL      = URL(string: "https://wifi.sncf/router/api/train/graph")!
    
    private let timeout: TimeInterval = 5

    /// Récupère toutes les infos en parallèle, notifie sur le main thread.
    func fetchAll(completion: @escaping (
        _ gps: [String: Any]?,
        _ details: [String: Any]?, // Retourne `progress` ou `details`
        _ bar: [String: Any]?,
        _ stats: [String: Any]?,
        _ status: [String: Any]?
    ) -> Void) {
        if MockTrainData.shared.isEnabled {
            // En mode démo, lire les données depuis le serveur local configurable.
            MockTrainData.shared.fetchAll(completion: completion)
            return
        }
        
        let group = DispatchGroup()
        
        var gpsData: [String: Any]?
        var progressData: [String: Any]?
        var detailsData: [String: Any]?
        var barData: [String: Any]?
        var statsData: [String: Any]?
        var statusData: [String: Any]?

        group.enter()
        fetch(url: gpsURL) { gpsData = $0; group.leave() }

        group.enter()
        fetch(url: progressURL) { progressData = $0; group.leave() }
        
        group.enter()
        fetch(url: detailsURL) { detailsData = $0; group.leave() }

        group.enter()
        fetch(url: barURL) { barData = $0; group.leave() }

        group.enter()
        fetch(url: statsURL) { statsData = $0; group.leave() }

        group.enter()
        fetch(url: statusURL) { statusData = $0; group.leave() }

        group.notify(queue: .main) {
            completion(gpsData, progressData ?? detailsData, barData, statsData, statusData)
        }
    }

    /// Récupère les données nécessaires à la carte : tracé exact, position live et arrêts.
    /// Le tracé est une LineString GeoJSON ; la vitesse se trouve dans le payload GPS.
    func fetchMapData(completion: @escaping (
        _ graph: [String: Any]?,
        _ gps: [String: Any]?,
        _ details: [String: Any]?
    ) -> Void) {
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.fetchMapData(completion: completion)
            return
        }

        let group = DispatchGroup()
        var graphData: [String: Any]?
        var gpsData: [String: Any]?
        var progressData: [String: Any]?
        var detailsData: [String: Any]?

        group.enter()
        fetch(url: graphURL) { graphData = $0; group.leave() }

        group.enter()
        fetch(url: gpsURL) { gpsData = $0; group.leave() }

        group.enter()
        fetch(url: progressURL) { progressData = $0; group.leave() }

        group.enter()
        fetch(url: detailsURL) { detailsData = $0; group.leave() }

        group.notify(queue: .main) {
            completion(graphData, gpsData, progressData ?? detailsData)
        }
    }

    /// Position seule. La carte la sonde à haute fréquence pour animer le déplacement : elle ne
    /// peut pas passer par `fetchMapData`, qui retéléchargerait le graphe complet à chaque appel.
    func fetchGPS(completion: @escaping ([String: Any]?) -> Void) {
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.fetchGPS(completion: completion)
            return
        }

        fetch(url: gpsURL) { data in
            DispatchQueue.main.async { completion(data) }
        }
    }

    private func fetch(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        HTTPJSON.fetchObject(url: url, timeout: timeout, completion: completion)
    }
}
