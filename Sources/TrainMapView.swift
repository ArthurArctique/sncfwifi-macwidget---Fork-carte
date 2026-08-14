import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// Dimensions du popover en mode carte. Plus large que le panneau d'informations : un trajet qui
/// traverse la France est illisible dans 300 pt.
enum TrainMapLayout {
    static let width: CGFloat = 420
    static let height: CGFloat = 440
}

// MARK: - Vue SwiftUI

/// Carte du trajet, affichée à la place du panneau d'informations dans le même popover.
struct TrainMapView: View {
    @ObservedObject var model: TrainMapModel
    let accent: Color
    let onBack: () -> Void

    /// Incrémenté pour demander un recadrage sur l'ensemble du tracé.
    @State private var overviewToken = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .bottomTrailing) {
                TrainMapRepresentable(model: model,
                                      accent: NSColor(accent),
                                      overviewToken: overviewToken)
                controls
                    .padding(10)
            }
        }
        .frame(width: TrainMapLayout.width, height: TrainMapLayout.height)
        // Le sondage à haute fréquence ne tourne que tant que la carte est à l'écran.
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(accent)
            .help("Revenir aux informations")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.trainNumber.map { "TGV INOUI n° \($0)" } ?? "Carte du trajet")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var controls: some View {
        Button {
            if model.followsTrain {
                model.followsTrain = false
                overviewToken += 1
            } else {
                model.followsTrain = true
            }
        } label: {
            Label(model.followsTrain ? "Vue d'ensemble" : "Suivre le train",
                  systemImage: model.followsTrain ? "map" : "location.fill")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderless)
        .foregroundColor(.white)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent)
                .shadow(color: Color.black.opacity(0.28), radius: 4, y: 1)
        )
    }
}

// MARK: - Pont AppKit

/// `MKMapView` piloté directement par son coordinateur.
///
/// L'animation de la position ne passe pas par SwiftUI : un relevé arrive chaque seconde, mais le
/// marqueur bouge une trentaine de fois par seconde. Republier cette position dans un `@Published`
/// reconstruirait tout le panneau à chaque image. Le coordinateur écrit donc directement dans
/// l'annotation MapKit ; SwiftUI ne voit passer que les relevés.
private struct TrainMapRepresentable: NSViewRepresentable {
    /// Observé par `TrainMapView`, donc `updateNSView` est rappelée à chaque relevé.
    @ObservedObject var model: TrainMapModel
    let accent: NSColor
    let overviewToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, accent: accent) }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = ScrollZoomMapView()
        mapView.delegate = context.coordinator
        // `mutedStandard` est le fond conçu pour recevoir des données par-dessus : les couleurs
        // d'Apple s'effacent, le carmillon du tracé ressort.
        mapView.mapType = .mutedStandard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsZoomControls = false
        mapView.showsScale = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.apply(overviewToken: overviewToken)
    }

    static func dismantleNSView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {

        /// 30 images par seconde suffisent pour une translation continue, et ne coûtent qu'une
        /// poignée d'opérations : MapKit ne redessine que l'annotation déplacée.
        private let tickInterval: TimeInterval = 1.0 / 30.0
        /// Vitesse de rattrapage de l'écart entre position extrapolée et dernier relevé, par
        /// seconde. Assez lent pour rester invisible, assez rapide pour coller au GPS.
        private let correctionRate: Double = 1.5
        /// Au-delà, ce n'est plus une dérive mais un saut (premier relevé, reprise après coupure) :
        /// on se replace d'un coup plutôt que de traverser la France en glissant.
        private let snapThreshold: CLLocationDistance = 2000

        /// Largeur de vue visée quand le suivi s'enclenche. On ne dézoome jamais pour l'atteindre :
        /// si l'utilisateur était déjà plus près, son échelle est conservée.
        private static let followMeters: CLLocationDistance = 20_000
        /// Garde-fou si `regionDidChangeAnimated` ne venait pas conclure l'accroche : sans lui, un
        /// suivi resté « en cours d'animation » ne recentrerait plus jamais.
        private static let followEngageTimeout: TimeInterval = 2

        private weak var mapView: MKMapView?
        private let model: TrainMapModel
        private let accent: NSColor
        private let trainAnnotation = TrainAnnotation()
        private var routeOverlay: MKPolyline?
        private var stopAnnotations: [StopAnnotation] = []
        private var ticker: Timer?

        // Géométrie du tracé, préparée une fois par trajet.
        private var mapPoints: [MKMapPoint] = []
        /// Distance depuis le départ, sommet par sommet (mètres).
        private var cumulative: [CLLocationDistance] = []
        private var routeFingerprint: String = ""
        private var stopsFingerprint: String = ""
        private var appliedOverviewToken = 0
        private var hasRestoredCamera = false

        // État de l'extrapolation.
        private var displayedDistance: CLLocationDistance?
        private var targetDistance: CLLocationDistance?
        private var speedMS: Double = 0
        private var displayedCoordinate: CLLocationCoordinate2D?
        private var targetCoordinate: CLLocationCoordinate2D?
        private var lastTick: Date?
        private var wasFollowing = false
        private var followEngagedAt: Date?

        init(model: TrainMapModel, accent: NSColor) {
            self.model = model
            self.accent = accent
            super.init()
        }

        // MARK: Cycle de vie

        func attach(to mapView: MKMapView) {
            self.mapView = mapView
            // Mode `.common` : sans lui, l'animation se fige pendant que l'utilisateur fait
            // glisser la carte — précisément quand le mouvement doit rester fluide.
            let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }

        func detach() {
            saveCamera()
            ticker?.invalidate()
            ticker = nil
            mapView = nil
        }

        // MARK: Entrées

        func apply(overviewToken: Int) {
            restoreCameraIfNeeded()
            applyRoute(model.route)
            applyStops(model.stops)
            applyFix(model.fix)

            if overviewToken != appliedOverviewToken {
                appliedOverviewToken = overviewToken
                frameRoute(animated: true)
            }

            // Front montant du suivi : c'est le clic sur « Suivre le train ».
            if model.followsTrain && !wasFollowing {
                engageFollow()
            }
            wasFollowing = model.followsTrain

            saveCamera()
        }

        /// Amène la carte sur le train et resserre la vue, avant que le recentrage continu prenne
        /// le relais.
        private func engageFollow() {
            guard let mapView, mapView.bounds.width > 0 else { return }
            let pointsPerMeter = MKMapPointsPerMeterAtLatitude(mapView.centerCoordinate.latitude)
            let currentMeters = pointsPerMeter > 0
                ? mapView.visibleMapRect.size.width / pointsPerMeter
                : Self.followMeters
            let meters = min(currentMeters, Self.followMeters)

            followEngagedAt = Date()
            mapView.setRegion(MKCoordinateRegion(center: trainAnnotation.coordinate,
                                                 latitudinalMeters: meters,
                                                 longitudinalMeters: meters),
                              animated: true)
        }

        // MARK: Cadrage conservé entre deux ouvertures

        /// La `MKMapView` est recréée à chaque retour sur la carte : on lui rend le cadrage
        /// quitté. Attendre que la vue ait une taille est indispensable — appliquer un
        /// `visibleMapRect` sur des bornes nulles donne un cadrage aberrant.
        private func restoreCameraIfNeeded() {
            guard !hasRestoredCamera,
                  let mapView,
                  mapView.bounds.width > 0, mapView.bounds.height > 0
            else { return }

            hasRestoredCamera = true
            guard let saved = model.savedVisibleRect else { return }
            mapView.visibleMapRect = saved
        }

        private func saveCamera() {
            guard hasRestoredCamera, let mapView, mapView.bounds.width > 0 else { return }
            model.savedVisibleRect = mapView.visibleMapRect
        }

        private func applyRoute(_ route: [CLLocationCoordinate2D]) {
            let fingerprint = RouteGeometry.fingerprint(route)
            guard fingerprint != routeFingerprint else { return }
            routeFingerprint = fingerprint

            mapPoints = route.map(MKMapPoint.init)
            cumulative = Self.cumulativeDistances(mapPoints)
            displayedDistance = nil
            targetDistance = nil

            guard let mapView else { return }
            if let previous = routeOverlay {
                mapView.removeOverlay(previous)
                routeOverlay = nil
            }
            guard route.count >= 2 else { return }

            let polyline = MKPolyline(coordinates: route, count: route.count)
            mapView.addOverlay(polyline, level: .aboveRoads)
            routeOverlay = polyline

            // Cadrage d'office sur le trajet seulement s'il n'y a rien à restaurer : au retour
            // sur la carte, le tracé est réinstallé mais le cadrage de l'utilisateur prime.
            if model.savedVisibleRect == nil {
                frameRoute(animated: false)
            }
        }

        private func applyStops(_ stops: [MapStop]) {
            let fingerprint = stops.map(\.id).joined(separator: "|")
            guard fingerprint != stopsFingerprint else { return }
            stopsFingerprint = fingerprint

            guard let mapView else { return }
            mapView.removeAnnotations(stopAnnotations)
            stopAnnotations = stops.map { StopAnnotation(stop: $0) }
            mapView.addAnnotations(stopAnnotations)
        }

        private func applyFix(_ fix: TrainFix?) {
            guard let fix else { return }
            speedMS = fix.speedMS
            targetCoordinate = fix.coordinate

            if mapView?.annotations.contains(where: { $0 === trainAnnotation }) != true {
                trainAnnotation.coordinate = fix.coordinate
                mapView?.addAnnotation(trainAnnotation)
            }

            targetDistance = distanceAlongRoute(of: fix.coordinate)
            if displayedDistance == nil {
                displayedDistance = targetDistance
                displayedCoordinate = fix.coordinate
            }
        }

        // MARK: Animation

        private func tick() {
            let now = Date()
            let elapsed = min(now.timeIntervalSince(lastTick ?? now), 0.5)
            lastTick = now
            guard elapsed > 0 else { return }

            if !cumulative.isEmpty, let target = targetDistance {
                var displayed = displayedDistance ?? target
                if abs(target - displayed) > snapThreshold {
                    displayed = target
                } else {
                    // Filtre complémentaire : on avance à la vitesse annoncée, et on résorbe
                    // doucement l'écart avec le dernier relevé réel.
                    displayed += speedMS * elapsed
                    displayed += (target - displayed) * min(1, correctionRate * elapsed)
                }
                displayed = min(max(displayed, 0), cumulative.last ?? 0)
                displayedDistance = displayed
                trainAnnotation.coordinate = coordinate(atDistance: displayed)
            } else if let target = targetCoordinate {
                // Repli sans tracé : interpolation directe entre deux relevés.
                let current = displayedCoordinate ?? target
                let blend = min(1, correctionRate * elapsed)
                let next = CLLocationCoordinate2D(
                    latitude: current.latitude + (target.latitude - current.latitude) * blend,
                    longitude: current.longitude + (target.longitude - current.longitude) * blend
                )
                displayedCoordinate = next
                trainAnnotation.coordinate = next
            } else {
                return
            }

            followTrainIfNeeded()
        }

        /// Garde le train exactement au centre de la carte, image par image. Le zoom reste à la
        /// main de l'utilisateur : seul le centrage est imposé.
        private func followTrainIfNeeded() {
            guard model.followsTrain, let mapView else { return }

            // Tant que l'animation d'accroche n'a pas fini, on la laisse aller : un recentrage
            // image par image l'interromprait, et le zoom resterait figé à mi-course.
            if let engagedAt = followEngagedAt {
                guard Date().timeIntervalSince(engagedAt) > Self.followEngageTimeout else { return }
                followEngagedAt = nil
            }
            mapView.setCenter(trainAnnotation.coordinate, animated: false)
        }

        private func frameRoute(animated: Bool) {
            guard let mapView else { return }
            if let polyline = routeOverlay {
                mapView.setVisibleMapRect(polyline.boundingMapRect,
                                          edgePadding: NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28),
                                          animated: animated)
            } else if let coordinate = targetCoordinate {
                mapView.setRegion(MKCoordinateRegion(center: coordinate,
                                                     latitudinalMeters: 40_000,
                                                     longitudinalMeters: 40_000),
                                  animated: animated)
            }
        }

        // MARK: Géométrie du tracé

        private static func cumulativeDistances(_ points: [MKMapPoint]) -> [CLLocationDistance] {
            guard points.count >= 2 else { return [] }
            var result: [CLLocationDistance] = [0]
            result.reserveCapacity(points.count)
            for index in 1..<points.count {
                result.append(result[index - 1] + points[index - 1].distance(to: points[index]))
            }
            return result
        }

        /// Position sur le tracé, en mètres depuis le départ.
        private func coordinate(atDistance distance: CLLocationDistance) -> CLLocationCoordinate2D {
            guard mapPoints.count >= 2, let total = cumulative.last, total > 0 else {
                return trainAnnotation.coordinate
            }
            let index = segmentIndex(forDistance: distance)
            let start = cumulative[index]
            let length = cumulative[index + 1] - start
            let ratio = length > 0 ? (distance - start) / length : 0
            let a = mapPoints[index]
            let b = mapPoints[index + 1]
            return MKMapPoint(x: a.x + (b.x - a.x) * ratio,
                              y: a.y + (b.y - a.y) * ratio).coordinate
        }

        /// Index du segment contenant `distance` (recherche dichotomique sur les cumuls).
        private func segmentIndex(forDistance distance: CLLocationDistance) -> Int {
            var low = 0
            var high = cumulative.count - 2
            while low < high {
                let middle = (low + high + 1) / 2
                if cumulative[middle] <= distance { low = middle } else { high = middle - 1 }
            }
            return max(0, min(low, cumulative.count - 2))
        }

        /// Projette un relevé GPS sur le tracé et renvoie sa distance depuis le départ.
        ///
        /// La recherche est fenêtrée autour de la position courante : une ligne ferroviaire repasse
        /// près d'elle-même (raccordements, gares traversées deux fois), et un balayage complet
        /// accrocherait alors le mauvais tronçon. Au premier relevé, faute de repère, on balaye tout.
        private func distanceAlongRoute(of coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
            guard mapPoints.count >= 2 else { return nil }
            let whole = 0..<(mapPoints.count - 1)

            var window = whole
            if let displayed = displayedDistance {
                let reach: CLLocationDistance = 15_000
                let lower = segmentIndex(forDistance: max(0, displayed - reach))
                let upper = segmentIndex(forDistance: displayed + reach)
                window = lower..<max(lower + 1, min(upper + 1, mapPoints.count - 1))
            }

            var best = project(coordinate, in: window)
            // Fenêtre bredouille : le train a pu s'éloigner du tracé puis y revenir ailleurs
            // (perte GPS prolongée). Sans ce second passage, la position de repli resterait
            // indéfiniment hors tracé.
            if best.gap > 3_000, window != whole {
                best = project(coordinate, in: whole)
            }

            // Relevé toujours trop loin du tracé (graphe d'un autre trajet, GPS aberrant) : mieux
            // vaut l'interpolation directe entre relevés que de coller le train sur des rails qui
            // ne sont pas les siens.
            return best.gap <= 3_000 ? best.along : nil
        }

        /// Projette un point sur les segments de `range` ; renvoie l'écart au tracé et la distance
        /// parcourue correspondante.
        private func project(_ coordinate: CLLocationCoordinate2D,
                             in range: Range<Int>) -> (gap: CLLocationDistance, along: CLLocationDistance) {
            let point = MKMapPoint(coordinate)
            var bestGap = CLLocationDistance.greatestFiniteMagnitude
            var bestAlong: CLLocationDistance = 0

            for index in range {
                let a = mapPoints[index]
                let b = mapPoints[index + 1]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let lengthSquared = dx * dx + dy * dy
                let ratio: Double = lengthSquared > 0
                    ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
                    : 0
                let projected = MKMapPoint(x: a.x + dx * ratio, y: a.y + dy * ratio)
                let gap = projected.distance(to: point)
                if gap < bestGap {
                    bestGap = gap
                    bestAlong = cumulative[index] + (cumulative[index + 1] - cumulative[index]) * ratio
                }
            }
            return (bestGap, bestAlong)
        }

        // MARK: MKMapViewDelegate

        /// Fin de l'animation d'accroche : le recentrage continu peut prendre le relais. Les
        /// recentrages image par image, eux, ne sont pas animés et ne passent donc pas ici.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if animated {
                followEngagedAt = nil
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = accent
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation === trainAnnotation {
                let identifier = "train"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.disc(diameter: 18, fill: accent, ring: .white, ringWidth: 3)
                view.canShowCallout = false
                view.zPriority = .max
                return view
            }

            guard annotation is StopAnnotation else { return nil }
            let identifier = "stop"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.image = Self.disc(diameter: 10,
                                   fill: NSColor(srgbRed: 0.90, green: 0.64, blue: 0.0, alpha: 1),
                                   ring: .white,
                                   ringWidth: 2)
            view.canShowCallout = true
            return view
        }

        private static func disc(diameter: CGFloat, fill: NSColor, ring: NSColor, ringWidth: CGFloat) -> NSImage {
            let image = NSImage(size: NSSize(width: diameter, height: diameter))
            image.lockFocus()
            let inset = ringWidth / 2
            let path = NSBezierPath(ovalIn: NSRect(x: inset,
                                                   y: inset,
                                                   width: diameter - ringWidth,
                                                   height: diameter - ringWidth))
            fill.setFill()
            path.fill()
            ring.setStroke()
            path.lineWidth = ringWidth
            path.stroke()
            image.unlockFocus()
            return image
        }
    }
}

// MARK: - Carte zoomable au défilement

/// `MKMapView` dont le défilement vertical zoome au lieu de déplacer la carte.
///
/// MapKit traite un défilement à deux doigts comme un déplacement, alors que dans un popover de
/// 420 pt c'est le zoom qu'on attend — et il n'y avait aucun autre moyen de zoomer au trackpad
/// sans pincer. Le défilement horizontal garde son déplacement d'origine, et le pincement continue
/// de fonctionner tel quel.
private final class ScrollZoomMapView: MKMapView {

    /// Sens du geste : deux doigts vers le haut = zoom avant, avec le défilement naturel de macOS.
    ///
    /// On utilise `scrollingDeltaY` brut, sans corriger `isDirectionInvertedFromDevice` : le zoom
    /// suit ainsi le réglage « sens du défilement » du système, comme le reste de macOS. Inverser
    /// ce réglage inverse aussi le zoom, ce qui est le comportement attendu.
    private static let zoomInSign: Double = 1

    /// Diviseurs du delta de défilement. Le trackpad envoie beaucoup de petits deltas, la molette
    /// quelques gros crans : sans ces deux échelles, l'un des deux serait inutilisable.
    private static let trackpadUnit: Double = 250
    private static let wheelUnit: Double = 6

    /// Largeur minimale de la vue, pour ne pas zoomer jusqu'à perdre tout repère.
    private static let minVisibleMeters: CLLocationDistance = 150

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }

        let scroll = Double(event.scrollingDeltaY)
        guard scroll != 0 else { return }

        let unit = event.hasPreciseScrollingDeltas ? Self.trackpadUnit : Self.wheelUnit
        zoom(by: pow(2, Self.zoomInSign * scroll / unit),
             around: convert(event.locationInWindow, from: nil))
    }

    /// Met la carte à l'échelle en laissant sous le curseur le point qui s'y trouvait.
    private func zoom(by factor: Double, around point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0, factor > 0 else { return }

        let anchor = MKMapPoint(convert(point, toCoordinateFrom: self))
        let rect = visibleMapRect

        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(centerCoordinate.latitude)
        let minWidth = Self.minVisibleMeters * pointsPerMeter
        let width = min(max(rect.size.width * factor, minWidth), MKMapRect.world.size.width)
        let scale = width / rect.size.width

        // Proportions de l'ancre dans la vue : ce sont elles qu'on conserve.
        let ratioX = (anchor.x - rect.origin.x) / rect.size.width
        let ratioY = (anchor.y - rect.origin.y) / rect.size.height
        let size = MKMapSize(width: rect.size.width * scale, height: rect.size.height * scale)

        setVisibleMapRect(MKMapRect(origin: MKMapPoint(x: anchor.x - size.width * ratioX,
                                                       y: anchor.y - size.height * ratioY),
                                    size: size),
                          animated: false)
    }
}

// MARK: - Annotations

private final class TrainAnnotation: MKPointAnnotation {}

private final class StopAnnotation: MKPointAnnotation {
    init(stop: MapStop) {
        super.init()
        coordinate = stop.coordinate
        title = stop.label
    }
}
