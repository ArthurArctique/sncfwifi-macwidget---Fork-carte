import Combine
import CoreLocation
import Foundation
import MapKit

/// Un arrêt de la desserte, positionné sur la carte.
struct MapStop: Identifiable {
    let id: String
    let label: String
    let coordinate: CLLocationCoordinate2D
}

/// Un relevé GPS du train.
struct TrainFix {
    let coordinate: CLLocationCoordinate2D
    /// Vitesse instantanée en m/s, telle que renvoyée par l'API.
    let speedMS: Double
    let date: Date

    var speedKmh: Int { Int(min(max(speedMS, 0) * 3.6, 1000)) }
}

/// Alimente la carte du trajet.
///
/// Le tracé et la desserte sont figés pour un trajet donné : ils ne sont demandés qu'à l'ouverture.
/// Seule la position est sondée en continu, et uniquement tant que la carte est visible —
/// `start()` et `stop()` sont appelés à l'apparition et à la disparition de la vue, ainsi qu'à la
/// fermeture du popover. `train/gps` tient dans une centaine d'octets servis par le réseau local
/// de la rame : une requête par seconde n'a pas d'effet mesurable, là où retélécharger le graphe
/// complet (plusieurs milliers de points) en aurait un.
final class TrainMapModel: ObservableObject {

    /// Tracé exact du trajet, dans l'ordre de parcours. Vide tant que le graphe n'a pas répondu.
    @Published private(set) var route: [CLLocationCoordinate2D] = []
    @Published private(set) var stops: [MapStop] = []
    /// Dernier relevé reçu. Entre deux relevés, la carte extrapole elle-même le déplacement.
    @Published private(set) var fix: TrainFix?
    @Published private(set) var trainNumber: String?
    @Published private(set) var statusText = "Chargement du trajet…"

    /// Suivi automatique du train par la carte.
    @Published var followsTrain = false

    /// Dernier cadrage de la carte (centre + zoom). Conservé ici, et non dans la vue, parce que
    /// SwiftUI détruit la `MKMapView` dès qu'on revient aux informations : sans ça, rouvrir la
    /// carte recadrerait sur l'ensemble du trajet et perdrait le zoom de l'utilisateur.
    /// Remis à zéro quand le tracé change, pour recadrer sur le nouveau trajet.
    var savedVisibleRect: MKMapRect?

    private let apiClient = TrainAPIClient()
    private var fixTimer: Timer?
    private var isFetchingFix = false
    private var isRunning = false
    private var lastRouteFetch: Date?

    /// Cadence de sondage de la position.
    private let fixInterval: TimeInterval = 1

    /// Fraîcheur au-delà de laquelle le tracé est redemandé à l'ouverture de la carte. Le graphe
    /// pèse bien plus lourd qu'un relevé GPS et ne change qu'entre deux trajets : le redemander à
    /// chaque ouverture gaspillerait le quota de données du train, ne jamais le redemander
    /// figerait la carte sur le trajet précédent après un changement de train.
    private let routeMaxAge: TimeInterval = 600

    // MARK: - Cycle de vie

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if route.isEmpty || Date().timeIntervalSince(lastRouteFetch ?? .distantPast) > routeMaxAge {
            fetchRoute()
        }
        fetchFix()

        // Mode `.common` : sans lui, le timer se met en pause pendant que l'utilisateur fait
        // glisser la carte — c'est justement le moment où la position doit continuer d'avancer.
        let timer = Timer(timeInterval: fixInterval, repeats: true) { [weak self] _ in
            self?.fetchFix()
        }
        RunLoop.main.add(timer, forMode: .common)
        fixTimer = timer
    }

    func stop() {
        isRunning = false
        fixTimer?.invalidate()
        fixTimer = nil
    }

    // MARK: - Récupération

    private func fetchRoute() {
        apiClient.fetchMapData { [weak self] graph, gps, details in
            guard let self else { return }
            let coordinates = RouteGeometry.coordinates(from: graph)
            // Un graphe vide, c'est une requête qui a échoué, pas un trajet sans tracé : on garde
            // celui déjà affiché plutôt que de vider la carte à la moindre coupure.
            if !coordinates.isEmpty {
                self.lastRouteFetch = Date()
                if RouteGeometry.fingerprint(coordinates) != RouteGeometry.fingerprint(self.route) {
                    // Nouveau trajet : le cadrage mémorisé porte sur l'ancien, il n'a plus de sens.
                    self.savedVisibleRect = nil
                    self.route = coordinates
                }
            }

            let stops = Self.mapStops(from: details)
            if !stops.isEmpty {
                self.stops = stops
            }
            self.trainNumber = asNonEmptyString(details?["number"])
                ?? asNonEmptyString(details?["trainNumber"])
                ?? self.trainNumber
            if let fix = Self.trainFix(from: gps) {
                self.fix = fix
            }
            self.refreshStatusText()
        }
    }

    private func fetchFix() {
        // Si le réseau de la rame traîne, on laisse la requête en cours se terminer plutôt que
        // d'en empiler une nouvelle chaque seconde.
        guard !isFetchingFix else { return }
        isFetchingFix = true

        apiClient.fetchGPS { [weak self] payload in
            guard let self else { return }
            self.isFetchingFix = false
            guard self.isRunning else { return }
            if let fix = Self.trainFix(from: payload) {
                self.fix = fix
            }
            self.refreshStatusText()
        }
    }

    private func refreshStatusText() {
        guard let fix else {
            statusText = route.isEmpty ? "Trajet indisponible" : "Position GPS indisponible"
            return
        }
        let speed = fix.speedKmh > 0 ? "\(fix.speedKmh) km/h" : "À l'arrêt"
        statusText = route.isEmpty ? "\(speed) · tracé indisponible" : speed
    }

    // MARK: - Lecture des payloads

    private static func trainFix(from payload: [String: Any]?) -> TrainFix? {
        guard let payload,
              let latitude = asDouble(payload["latitude"]) ?? asDouble(payload["lat"]),
              let longitude = asDouble(payload["longitude"]) ?? asDouble(payload["lon"]) ?? asDouble(payload["lng"])
        else { return nil }

        // Perte de fix : la rame renvoie `fix: -1` avec latitude, longitude et altitude à zéro,
        // mais `success: true`. (0, 0) étant une coordonnée valide au large de l'Afrique,
        // `CLLocationCoordinate2DIsValid` ne suffit pas — sans ce filtre le marqueur file vers
        // le golfe de Guinée jusqu'au relevé suivant. Les fixes exploitables portent `fix` ≥ 1.
        if let fix = asInt(payload["fix"]), fix < 1 { return nil }
        if latitude == 0 && longitude == 0 { return nil }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let speed = asDouble(payload["speed"]) ?? 0
        return TrainFix(coordinate: coordinate,
                        speedMS: speed.isFinite ? max(0, speed) : 0,
                        date: Date())
    }

    private static func mapStops(from details: [String: Any]?) -> [MapStop] {
        guard let stops = details?["stops"] as? [[String: Any]] else { return [] }
        return stops.enumerated().compactMap { index, stop in
            guard let coordinates = stop["coordinates"] as? [String: Any],
                  let latitude = asDouble(coordinates["latitude"]),
                  let longitude = asDouble(coordinates["longitude"])
            else { return nil }

            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

            let label = asNonEmptyString(stop["label"]) ?? "Arrêt \(index + 1)"
            return MapStop(id: asNonEmptyString(stop["id"]) ?? "\(index)-\(label)",
                           label: label,
                           coordinate: coordinate)
        }
    }
}

// MARK: - Graphe GeoJSON

/// Lecture du tracé renvoyé par `train/graph`.
///
/// Les rames ne servent pas toutes la même enveloppe : tantôt la géométrie nue, tantôt une
/// `Feature`, tantôt une `FeatureCollection`, parfois encapsulée dans `data`. Les quatre sont
/// acceptées, plutôt que de parier sur une seule et de se retrouver avec une carte vide.
enum RouteGeometry {

    static func coordinates(from payload: [String: Any]?) -> [CLLocationCoordinate2D] {
        guard let payload else { return [] }

        if let geometry = payload["geometry"] as? [String: Any] {
            return coordinates(from: geometry)
        }
        if let features = payload["features"] as? [[String: Any]] {
            return features.flatMap { coordinates(from: $0) }
        }
        if let nested = payload["data"] as? [String: Any] {
            return coordinates(from: nested)
        }

        switch payload["type"] as? String {
        case "LineString":
            return line(from: payload["coordinates"])
        case "MultiLineString":
            guard let parts = payload["coordinates"] as? [Any] else { return [] }
            return parts.flatMap { line(from: $0) }
        default:
            return []
        }
    }

    /// Empreinte bon marché d'un tracé : inutile de comparer des milliers de points alors que le
    /// graphe ne change qu'entre deux trajets.
    static func fingerprint(_ route: [CLLocationCoordinate2D]) -> String {
        guard let first = route.first, let last = route.last else { return "vide" }
        return "\(route.count)|\(first.latitude),\(first.longitude)|\(last.latitude),\(last.longitude)"
    }

    /// GeoJSON ordonne chaque position en `[longitude, latitude]` — l'inverse de CoreLocation.
    private static func line(from value: Any?) -> [CLLocationCoordinate2D] {
        guard let points = value as? [Any] else { return [] }
        return points.compactMap { point in
            guard let pair = point as? [Any], pair.count >= 2,
                  let longitude = asDouble(pair[0]),
                  let latitude = asDouble(pair[1])
            else { return nil }

            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
    }
}
