import CoreLocation
import Foundation

/// Profil altimétrique d'un trajet, et dénivelé positif cumulé le long de celui-ci.
///
/// L'API du train ne fournit aucune altitude en dehors de la position instantanée : le graphe
/// (`train/graph`) est en deux dimensions et les arrêts n'en portent pas. Le profil est donc
/// reconstitué à partir du RGE ALTI de l'IGN, interrogé une fois par trajet.
///
/// Deux précautions rendent le chiffre honnête :
///
/// - **Rééchantillonnage à pas constant.** Le dénivelé dépend de la finesse à laquelle on suit le
///   terrain ; l'espacement du graphe SNCF varie d'un trajet à l'autre, il ne doit pas décider du
///   résultat.
/// - **Lissage sur `smoothingMeters`.** Le RGE ALTI donne l'altitude du *sol*, pas celle de la
///   *voie* : sur une ligne à grande vitesse, le train franchit les vallées en viaduc et les
///   collines en tranchée. Mesuré sur 29 km de LGV réelle, le brut donnait 244 m de D+ quand le
///   GPS du train en relevait 69 — un facteur 3,5. Après lissage à la même échelle, les deux
///   sources concordent à 5 % près.
///
/// Le résultat reste une **estimation** : la valeur dépend de la fenêtre de lissage (environ 2 000 m
/// de D+ à 1 km de fenêtre, 1 150 m à 5 km, sur un Toulouse–Lyon). La convention retenue est
/// annoncée dans l'interface.
struct ElevationProfile {

    /// Pas de rééchantillonnage du tracé, en mètres.
    static let sampleSpacing: CLLocationDistance = 200
    /// Largeur de la fenêtre de lissage, en mètres.
    static let smoothingMeters: CLLocationDistance = 2_000

    /// Points du tracé, régulièrement espacés de `sampleSpacing`.
    let points: [CLLocationCoordinate2D]
    /// Altitude lissée à chaque point, en mètres.
    let altitudes: [Double]
    /// Dénivelé positif cumulé depuis le départ, à chaque point.
    let cumulativeGain: [Double]

    /// Dénivelé positif total du trajet.
    var totalGain: Double { cumulativeGain.last ?? 0 }

    /// Dénivelé positif cumulé depuis le départ jusqu'au point du tracé le plus proche.
    ///
    /// La projection se fait au point le plus proche plutôt que par abscisse curviligne : les
    /// gares sont à quelques dizaines de mètres du tracé, et le pas de 200 m rend la distinction
    /// sans effet sur le résultat.
    func gain(at coordinate: CLLocationCoordinate2D) -> Double? {
        guard let index = nearestIndex(to: coordinate) else { return nil }
        return cumulativeGain[index]
    }

    private func nearestIndex(to coordinate: CLLocationCoordinate2D) -> Int? {
        guard !points.isEmpty else { return nil }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for (index, point) in points.enumerated() {
            let distance = CLLocation(latitude: point.latitude, longitude: point.longitude)
                .distance(from: target)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        // Au-delà, la gare n'appartient pas à ce tracé : mieux vaut ne rien afficher qu'un chiffre
        // pris sur un autre bout de ligne.
        return bestDistance <= 5_000 ? best : nil
    }

    // MARK: - Construction

    /// Rééchantillonne `route` à pas constant. Renvoie `nil` si le tracé est inexploitable.
    static func resample(_ route: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D]? {
        guard route.count >= 2 else { return nil }

        var cumulative: [CLLocationDistance] = [0]
        for (a, b) in zip(route, route.dropFirst()) {
            let step = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            cumulative.append(cumulative[cumulative.count - 1] + step)
        }
        guard let total = cumulative.last, total > sampleSpacing else { return nil }

        var samples: [CLLocationCoordinate2D] = []
        var segment = 0
        var travelled: CLLocationDistance = 0
        while travelled <= total {
            while segment < cumulative.count - 2 && cumulative[segment + 1] < travelled { segment += 1 }
            let length = cumulative[segment + 1] - cumulative[segment]
            let ratio = length > 0 ? (travelled - cumulative[segment]) / length : 0
            let a = route[segment]
            let b = route[segment + 1]
            samples.append(CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * ratio,
                longitude: a.longitude + (b.longitude - a.longitude) * ratio))
            travelled += sampleSpacing
        }
        return samples
    }

    /// Assemble le profil à partir des altitudes brutes renvoyées pour `points`.
    static func make(points: [CLLocationCoordinate2D], rawAltitudes: [Double]) -> ElevationProfile? {
        guard points.count == rawAltitudes.count, points.count >= 2 else { return nil }

        let half = max(1, Int((smoothingMeters / sampleSpacing / 2).rounded()))
        var smoothed: [Double] = []
        smoothed.reserveCapacity(rawAltitudes.count)
        for index in rawAltitudes.indices {
            let window = rawAltitudes[max(0, index - half)...min(rawAltitudes.count - 1, index + half)]
            smoothed.append(window.reduce(0, +) / Double(window.count))
        }

        var gains: [Double] = [0]
        gains.reserveCapacity(smoothed.count)
        for (a, b) in zip(smoothed, smoothed.dropFirst()) {
            gains.append(gains[gains.count - 1] + max(0, b - a))
        }
        return ElevationProfile(points: points, altitudes: smoothed, cumulativeGain: gains)
    }
}

// MARK: - Client IGN

/// Interroge le RGE ALTI de l'IGN (Géoplateforme), service public français, pour l'altitude d'une
/// liste de points.
///
/// C'est le seul appel de l'app à un service extérieur au train, hors tuiles de la carte. Les
/// coordonnées du trajet y sont envoyées. Un aller-retour complet coûte trois requêtes et environ
/// 150 Ko pour un trajet de 550 km, une seule fois par trajet.
enum ElevationClient {

    private static let endpoint = URL(string: "https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json")!
    /// Le service accepte au moins un millier de points par requête.
    private static let batchSize = 1_000
    private static let timeout: TimeInterval = 30

    /// Altitudes de `points`, dans le même ordre. `nil` si une requête échoue : un profil partiel
    /// donnerait un dénivelé faux, ce qui est pire que pas de dénivelé du tout.
    static func altitudes(for points: [CLLocationCoordinate2D],
                          completion: @escaping ([Double]?) -> Void) {
        guard !points.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        let batches = stride(from: 0, to: points.count, by: batchSize).map {
            Array(points[$0..<min($0 + batchSize, points.count)])
        }

        let group = DispatchGroup()
        var results = [Int: [Double]]()
        let lock = NSLock()

        for (index, batch) in batches.enumerated() {
            group.enter()
            fetchBatch(batch) { altitudes in
                lock.lock()
                results[index] = altitudes
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            var assembled: [Double] = []
            for index in batches.indices {
                guard let batch = results[index] else { completion(nil); return }
                assembled += batch
            }
            completion(assembled.count == points.count ? assembled : nil)
        }
    }

    private static func fetchBatch(_ points: [CLLocationCoordinate2D],
                                   completion: @escaping ([Double]?) -> Void) {
        let body: [String: Any] = [
            "resource": "ign_rge_alti_wld",
            "lon": points.map { String(format: "%.6f", $0.longitude) }.joined(separator: ","),
            "lat": points.map { String(format: "%.6f", $0.latitude) }.joined(separator: ","),
            "delimiter": ","
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPJSON.userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["elevations"] as? [[String: Any]]
            else {
                completion(nil)
                return
            }

            // Le service renvoie -99999 là où il n'a pas de donnée : on interpole plutôt que de
            // laisser un trou, qui compterait comme une falaise dans le dénivelé.
            var altitudes: [Double] = []
            for entry in entries {
                let value = asDouble(entry["z"]) ?? -99_999
                altitudes.append(value > -1_000 ? value : (altitudes.last ?? 0))
            }
            completion(altitudes.count == points.count ? altitudes : nil)
        }.resume()
    }
}

// MARK: - Profil du trajet en cours

/// Détient le profil altimétrique du trajet courant et ne le reconstruit qu'au changement de train.
///
/// Le tracé et le profil sont figés pour un trajet donné, et leur obtention coûte une requête au
/// train plus trois à l'IGN : les refaire à chaque rafraîchissement serait un gaspillage du quota
/// de données embarqué.
final class RouteProfileStore {

    private let apiClient = TrainAPIClient()
    private var profile: ElevationProfile?
    private var loadedJourney: String?
    private var isLoading = false

    /// Appelée quand un profil vient d'être chargé, pour rafraîchir l'affichage.
    var onLoaded: () -> Void = {}

    /// Dénivelé positif cumulé depuis le départ, `nil` tant que le profil n'est pas disponible.
    func gain(at coordinate: CLLocationCoordinate2D) -> Double? {
        profile?.gain(at: coordinate)
    }

    var totalGain: Double? { profile?.totalGain }

    /// Demande le profil du trajet décrit par `journey`. Sans effet s'il est déjà chargé.
    ///
    /// - Parameter journey: empreinte du trajet (train et desserte). Un changement déclenche un
    ///   rechargement, faute de quoi on afficherait le dénivelé du trajet précédent.
    func load(journey: String) {
        guard journey != loadedJourney, !isLoading, !journey.isEmpty else { return }
        isLoading = true

        apiClient.fetchGraph { [weak self] graph in
            guard let self else { return }
            let route = RouteGeometry.coordinates(from: graph)
            guard let samples = ElevationProfile.resample(route) else {
                self.isLoading = false
                return
            }

            ElevationClient.altitudes(for: samples) { altitudes in
                self.isLoading = false
                guard let altitudes,
                      let profile = ElevationProfile.make(points: samples, rawAltitudes: altitudes)
                else { return }

                self.profile = profile
                self.loadedJourney = journey
                NSLog("[SNCFWifi] Profil altimétrique chargé : %.0f m de D+ sur %d points.",
                      profile.totalGain, samples.count)
                self.onLoaded()
            }
        }
    }

    /// Oublie le profil courant (changement d'opérateur, sortie du wifi du train).
    func reset() {
        profile = nil
        loadedJourney = nil
    }
}
