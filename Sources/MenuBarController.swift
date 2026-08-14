import Cocoa
import Combine
import CoreLocation
import CoreWLAN
import UserNotifications
import SwiftUI

final class MenuBarController: NSObject {

    // MARK: - Properties

    private let statusItem = MenuBarController.makeStatusItem()
    private let apiClient  = TrainAPIClient()
    private let eurostarClient = EurostarAPIClient()
    private var timer: Timer?
    private var clockTimer: Timer?
    private var lastRawData: [String: Any]?

    /// Nom d'autosauvegarde du `NSStatusItem` : c'est lui qui identifie la position mémorisée par
    /// macOS quand l'utilisateur déplace l'élément (⌘ + glisser).
    private static let statusItemAutosaveName = "SNCFWifiStatusItem"

    /// Position préférée initiale, en points depuis le bord droit de l'écran.
    ///
    /// Sans position enregistrée, macOS place un nouvel élément au premier emplacement libre en
    /// partant de la droite. Sur un MacBook à encoche dont la barre est déjà bien remplie, cet
    /// emplacement tombe *sous l'encoche* : l'élément existe et reste cliquable, mais il est
    /// totalement invisible — et le panneau semble alors surgir de la caméra. 400 pt le pose dans
    /// la zone des applications tierces, franchement à droite de l'encoche (large d'environ
    /// 180 pt, soit ~645 pt du bord droit sur un écran 13").
    private static let defaultPreferredPosition = 400

    /// Crée l'élément de barre des menus après avoir amorcé sa position préférée.
    ///
    /// L'amorçage n'a lieu qu'au tout premier lancement : dès que l'utilisateur déplace l'élément,
    /// macOS réécrit cette clé et son choix est conservé.
    private static func makeStatusItem() -> NSStatusItem {
        let positionKey = "NSStatusItem Preferred Position \(statusItemAutosaveName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(defaultPreferredPosition, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = statusItemAutosaveName
        return item
    }

    // Panneau flottant SwiftUI (remplace l'ancien NSMenu).
    private let store = TrainStore()
    private let popover = NSPopover()
    /// Source de la carte du trajet. Elle vit aussi longtemps que le contrôleur pour conserver le
    /// tracé déjà téléchargé d'une ouverture à l'autre ; seul son sondage démarre et s'arrête.
    private let mapModel = TrainMapModel()
    private var panelLayoutObserver: AnyCancellable?

    // Cache pour le redraw de l'icône sans appel API
    private var cachedArrivalDate: Date?
    private var cachedDestShort: String = ""
    private var cachedGlobalProgress: Double = 0.0
    private var cachedSpeed: Int = 0
    private var cachedIsStopped: Bool = false
    private var cachedStoppedStation: String = ""
    private var cachedDelayMins: Int = 0
    private var cachedDelayCause: String = ""
    // Opérateur du dernier rafraîchissement réussi : détermine la composition du titre.
    private var cachedOperator: TrainOperator = .sncf
    private var cachedDataRemainingMB: Double?
    private var cachedHasPosition: Bool = false
    private static let resetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
    private let locationManager = CLLocationManager()
    private let notificationCenter = UNUserNotificationCenter.current()

    /// Dernier opérateur ayant répondu : sert à sonder la bonne plateforme en premier quand le
    /// SSID est indisponible (droit Localisation refusé).
    private let lastKnownOperatorKey = "lastKnownOperator"

    private let notifyBeforeArrivalEnabledKey = "notifyBeforeArrivalEnabled"
    private let notifyBeforeArrivalMinutesKey = "notifyBeforeArrivalMinutes"
    private let notifyBeforeArrivalTargetKey = "notifyBeforeArrivalTarget"
    private let lastArrivalNotificationStopIdKey = "lastArrivalNotificationStopId"
    private let allowedNotificationLeadTimes = [5, 10, 15]

    private enum ArrivalNotificationTarget: String {
        case selectedArrival
        case nextStop
    }

    // MARK: - Init

    override init() {
        super.init()
        
        // Demande la permission de localisation pour lire le SSID (macOS 14.4+)
        locationManager.delegate = self
        requestSSIDAuthorizationIfNeeded()

        // Prépare les réglages de notifications locales (avant arrivée en gare).
        registerNotificationDefaults()
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Train")
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.toolTip = "SNCF WiFi"

        // Le clic sur l'icône ouvre/ferme le panneau flottant (et non un NSMenu).
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        configurePopover()

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSNotification.Name("DemoDataDidUpdate"), object: nil)
        
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.start()
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.redrawTitle()
        }

        // La position réelle n'est connue qu'une fois la barre des menus mise en page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.logStatusItemPlacement()
        }
    }

    /// Trace la position obtenue dans la barre des menus, et signale le cas où macOS a placé
    /// l'élément derrière l'encoche : il est alors invisible et impossible à cliquer, alors que
    /// l'application fonctionne normalement. Consultable avec :
    /// `log show --last 5m --predicate 'process == "SNCFWifi"'`
    private func logStatusItemPlacement() {
        guard let frame = statusItem.button?.window?.frame else {
            NSLog("[SNCFWifi] Élément de barre des menus sans fenêtre — non placé par macOS.")
            return
        }
        guard #available(macOS 12.0, *),
              let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            NSLog("[SNCFWifi] Élément de barre des menus placé en x %.0f–%.0f (écran sans encoche).",
                  frame.minX, frame.maxX)
            return
        }
        let notch = CGRect(x: left.maxX, y: frame.minY, width: right.minX - left.maxX, height: frame.height)
        if notch.intersects(frame) {
            NSLog("""
                  [SNCFWifi] Élément de barre des menus masqué par l'encoche : placé en x %.0f–%.0f, \
                  encoche en x %.0f–%.0f. Libérez de la place dans la barre des menus, ou déplacez \
                  l'élément avec ⌘ + glisser.
                  """, frame.minX, frame.maxX, notch.minX, notch.maxX)
        } else {
            NSLog("[SNCFWifi] Élément de barre des menus visible en x %.0f–%.0f (encoche en x %.0f–%.0f).",
                  frame.minX, frame.maxX, notch.minX, notch.maxX)
        }
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: TrainPanelView()
                .environmentObject(store)
                .environmentObject(mapModel)
        )

        // NSPopover se dimensionne à la première présentation et ne remesure jamais son contenu.
        // Or le panneau est encore vide à ce moment-là : sans ce réajustement, la bulle garde la
        // taille de l'état « chargement » jusqu'au premier changement de gabarit. On lui pousse
        // donc la taille calculée par SwiftUI dès que le contenu peut avoir changé — arrivée des
        // données du train comme bascule vers la carte.
        panelLayoutObserver = store.$showsMap.map { _ in }
            .merge(with: store.$state.map { _ in })
            .sink { [weak self] in
                DispatchQueue.main.async { self?.resizePopoverToContent() }
            }

        // Branche les actions du panneau sur les handlers existants.
        store.onRefresh = { [weak self] in self?.refresh() }
        store.onQuit = { NSApp.terminate(nil) }
        store.onSelectArrival = { [weak self] stopId in
            UserDefaults.standard.set(stopId, forKey: "arrivalStationId")
            self?.refresh()
        }
        store.onToggleDemo = { [weak self] in self?.toggleDemoMode() }
        store.onSetDemoOperator = { [weak self] op in
            MockTrainData.shared.demoOperator = op
            self?.refresh()
        }
        store.onOpenDemoPanel = { [weak self] in self?.openDemoControlPanel() }
        store.onCopyJSON = { [weak self] in self?.copyDebugData() }
        store.onOpenAbout = { [weak self] in self?.openAbout() }
        store.onSettingsChanged = { [weak self] in
            self?.lastArrivalNotifiedStopId = nil
            self?.refresh()
        }
    }

    private func resizePopoverToContent() {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        popover.contentSize = view.fittingSize
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // La vue n'a sa taille définitive qu'une fois montée dans la fenêtre du popover.
            DispatchQueue.main.async { [weak self] in self?.resizePopoverToContent() }
        }
    }

    @objc private func redrawTitle() {
        if cachedDelayMins > 0 {
            // Affiche le retard pendant 5s, puis repasse au texte normal
            var t = "⚠ +\(cachedDelayMins)min"
            if !cachedDelayCause.isEmpty { t += " · \(cachedDelayCause)" }
            applyTitleImage(text: t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.redrawNormalTitle()
            }
        } else {
            redrawNormalTitle()
        }
    }

    private func redrawNormalTitle() {
        if cachedOperator == .eurostar {
            applyTitleImage(text: eurostarTitleText())
            return
        }

        let text: String
        if cachedIsStopped && !cachedStoppedStation.isEmpty {
            text = stationLocationText(cachedStoppedStation)
        } else {
            var t = cachedDestShort
            if let arrival = cachedArrivalDate, arrival > Date() {
                let diffMins = Int(arrival.timeIntervalSinceNow / 60)
                let timeStr: String
                if diffMins >= 60 {
                    let h = diffMins / 60
                    let m = diffMins % 60
                    timeStr = m > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(h)h"
                } else {
                    timeStr = "\(diffMins)min"
                }
                t = t.isEmpty ? timeStr : "\(t) · \(timeStr)"
            }
            text = t
        }
        applyTitleImage(text: text)
    }

    /// Titre Eurostar : vitesse + data restante. La plateforme Icomera ne fournit ni destination
    /// ni heure d'arrivée, il n'y a donc rien d'autre à faire tenir dans la barre des menus.
    private func eurostarTitleText() -> String {
        var parts: [String] = []
        if cachedHasPosition {
            parts.append(cachedSpeed > 0 ? "\(cachedSpeed) km/h" : "À l'arrêt")
        }
        if let remaining = cachedDataRemainingMB {
            parts.append(DataVolume.compactLabel(remaining))
        }
        return parts.joined(separator: " · ")
    }

    private func applyTitleImage(text: String) {
        guard !text.isEmpty else { return }
        applyStatusItem(title: text,
                        image: StatusBarImageGenerator.draw(text: text, progress: cachedGlobalProgress))
    }

    /// Rendu de l'élément de barre : la pastille dessinée (texte + jauge de progression) quand
    /// elle a pu être générée, sinon l'icône du tram suivie du texte.
    private func applyStatusItem(title: String, image: NSImage?) {
        guard let button = statusItem.button else { return }
        if let image {
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Train")
            button.imagePosition = .imageLeft
            button.title = title.isEmpty ? "" : " \(title)"
        }
    }

    // MARK: - Refresh

    @objc func refresh() {
        if MockTrainData.shared.isEnabled {
            load(operator: MockTrainData.shared.demoOperator)
            return
        }

        let ssid = CWWiFiClient.shared().interface()?.ssid() ?? ""

        if ssid.isEmpty {
            // SSID indisponible (droit Localisation refusé, ou macOS antérieur à 14.4) : on ne
            // peut pas identifier le réseau, donc on sonde les plateformes en commençant par
            // celle qui a répondu la dernière fois. On s'arrête dès qu'une répond.
            advance(fallbacks: probeOrder())
            return
        }

        guard let detected = TrainOperator.matching(ssid: ssid) else {
            // Pas sur le wifi d'un train connu : on arrête ici pour économiser la batterie.
            DispatchQueue.main.async { [weak self] in self?.showNotConnected() }
            return
        }

        load(operator: detected)
    }

    /// Ordre de sondage quand le SSID est inconnu : dernier opérateur connu d'abord.
    private func probeOrder() -> [TrainOperator] {
        guard let last = lastKnownOperator else { return TrainOperator.allCases }
        return [last] + TrainOperator.allCases.filter { $0 != last }
    }

    /// Interroge la plateforme de `op`. Si elle ne répond rien d'exploitable, essaie `fallbacks`.
    private func load(operator op: TrainOperator, fallbacks: [TrainOperator] = []) {
        switch op {
        case .sncf:      loadSNCF(fallbacks: fallbacks)
        case .eurostar:  loadEurostar(fallbacks: fallbacks)
        }
    }

    /// Passe au prochain opérateur à sonder, ou affiche l'état déconnecté s'il n'y en a plus.
    private func advance(fallbacks: [TrainOperator]) {
        guard let next = fallbacks.first else {
            showNotConnected()
            return
        }
        load(operator: next, fallbacks: Array(fallbacks.dropFirst()))
    }

    private func showNotConnected() {
        statusItem.button?.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        store.lastRefreshDate = Date()
        store.state = .notConnected(demoMode: MockTrainData.shared.isEnabled)
    }

    /// Snapshot debug commun (SSID, mode démo, opérateur), enrichi par chaque plateforme.
    private func debugSnapshotBase(operator op: TrainOperator) -> [String: Any] {
        let ssidInfo = currentSSIDInfo()
        return [
            "operator": op.rawValue,
            "ssid": ssidInfo.ssid,
            "ssidStatus": ssidInfo.status,
            "demoMode": MockTrainData.shared.isEnabled,
            "demoServerURL": MockTrainData.shared.baseURLString
        ]
    }

    // MARK: - Refresh SNCF

    private func loadSNCF(fallbacks: [TrainOperator]) {
        apiClient.fetchAll { [weak self] gps, details, bar, stats, status in
            guard let self else { return }

            // Conserver un snapshot debug même si l'API est indisponible.
            var snapshot = self.debugSnapshotBase(operator: .sncf)
            if let g = gps { snapshot["gps"] = g }
            if let d = details { snapshot["details"] = d }
            if let b = bar { snapshot["bar"] = b }
            if let s = stats { snapshot["stats"] = s }
            if let st = status { snapshot["status"] = st }
            self.lastRawData = snapshot

            if gps == nil && details == nil {
                self.advance(fallbacks: fallbacks)
                return
            }

            self.lastKnownOperator = .sncf
            self.cachedOperator = .sncf
            self.cachedDataRemainingMB = nil
            self.cachedHasPosition = gps != nil

            let (title, customImage, viewState) = self.buildTrainState(gps: gps, details: details, bar: bar, stats: stats, status: status)
            self.applyStatusItem(title: title, image: customImage)
            self.store.lastRefreshDate = Date()
            self.store.state = .connected(viewState)
            // Applique le texte delay-aware (rotation) après avoir peuplé le cache
            if self.cachedArrivalDate != nil || self.cachedIsStopped {
                self.redrawTitle()
            }
        }
    }

    // MARK: - Refresh Eurostar

    private func loadEurostar(fallbacks: [TrainOperator]) {
        eurostarClient.fetchAll { [weak self] system, connectivity, users, user, position in
            guard let self else { return }

            var snapshot = self.debugSnapshotBase(operator: .eurostar)
            if let s = system { snapshot["system"] = s }
            if let c = connectivity { snapshot["connectivity"] = c }
            if let u = users { snapshot["users"] = u }
            if let u = user { snapshot["user"] = u }
            if let p = position { snapshot["position"] = p }
            self.lastRawData = snapshot

            guard EurostarStateBuilder.hasUsableData(connectivity: connectivity, position: position, user: user) else {
                self.advance(fallbacks: fallbacks)
                return
            }

            let viewState = EurostarStateBuilder.build(system: system,
                                                       connectivity: connectivity,
                                                       users: users,
                                                       user: user,
                                                       position: position)

            self.lastKnownOperator = .eurostar
            self.applyEurostarCache(viewState, hasPosition: position != nil)

            let text = self.eurostarTitleText()
            self.applyStatusItem(title: text,
                                 image: text.isEmpty ? nil : StatusBarImageGenerator.draw(text: text, progress: viewState.globalProgress))

            self.store.lastRefreshDate = Date()
            self.store.state = .connected(viewState)
        }
    }

    /// Aligne le cache du redraw périodique sur l'état Eurostar. Les champs propres à la desserte
    /// SNCF sont remis à zéro pour que le `clockTimer` ne réutilise pas un trajet précédent.
    private func applyEurostarCache(_ state: TrainViewState, hasPosition: Bool) {
        cachedOperator = .eurostar
        cachedGlobalProgress = state.globalProgress
        cachedSpeed = state.speedKmh
        cachedDataRemainingMB = state.dataRemainingMB
        cachedHasPosition = hasPosition
        cachedArrivalDate = nil
        cachedDestShort = ""
        cachedIsStopped = false
        cachedStoppedStation = ""
        cachedDelayMins = 0
        cachedDelayCause = ""
    }

    // MARK: - Construction de l'état du train (modèle de vue)

    private func buildTrainState(gps: [String: Any]?,
                                 details: [String: Any]?,
                                 bar: [String: Any]?,
                                 stats: [String: Any]?,
                                 status: [String: Any]?) -> (String, NSImage?, TrainViewState) {

        // L'API retourne la vitesse en m/s, on convertit en km/h (conversion bornée : cf.
        // ValueCoercion, `Int(_:)` sur un Double non fini est une erreur fatale).
        let speed = speedKmh(fromMetersPerSecond: gps?["speed"])

        var trainNumber:       String?
        var destinationLabel:  String?
        var nextStopLabel:     String?
        var nextStopIndex:     Int = 0
        var isStoppedAtStation: Bool = false
        var allStops:          [[String: Any]] = []
        var trainDelayMins:    Int = 0
        var trainDelayCause:   String = ""

        let currentLat = asDouble(gps?["latitude"]) ?? asDouble(gps?["lat"])
        let currentLon = asDouble(gps?["longitude"]) ?? asDouble(gps?["lon"]) ?? asDouble(gps?["lng"])

        let distanceToStop: ([String: Any]) -> Double = { stop in
            guard let lat = currentLat, let lon = currentLon,
                  let coords = stop["coordinates"] as? [String: Any],
                  let sLat = asDouble(coords["latitude"]),
                  let sLon = asDouble(coords["longitude"]) else {
                return 999999.0
            }
            return CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: sLat, longitude: sLon))
        }

        if let det = details {
            // "number" = numéro commercial du train (ex: 6201), "trainId" = numéro de rame matériel
            if let s = det["number"] as? String, !s.isEmpty {
                trainNumber = s
            } else if let n = det["number"] as? Int {
                trainNumber = String(n)
            } else if let n = det["number"] as? Double {
                trainNumber = String(Int(n))
            }

            allStops = (det["stops"] as? [[String: Any]]) ?? []
            destinationLabel = allStops.last?["label"]  as? String

            // Retard global du train — la valeur est sur chaque arrêt, pas à la racine
            trainDelayMins = safeInt(det["delay"])
            if trainDelayMins == 0 { trainDelayMins = safeInt(allStops.last?["delay"]) }

            // Raison du retard : d'abord dans events[], puis sur les arrêts
            if let events = det["events"] as? [[String: Any]] {
                trainDelayCause = events.first(where: { ($0["type"] as? String) == "RETARD" })
                    .flatMap { $0["text"] as? String } ?? ""
            }
            if trainDelayCause.isEmpty {
                trainDelayCause = (det["delayReason"] as? String)
                    ?? allStops.first(where: { ($0["delayReason"] as? String)?.isEmpty == false })
                        .flatMap { $0["delayReason"] as? String }
                    ?? ""
            }

            // Trouver le segment en cours (le premier qui n'est pas à 100%)
            var currentSegmentIndex = 0
            for (i, stop) in allStops.enumerated() {
                let progressDict = stop["progress"] as? [String: Any]
                let pct = (progressDict?["progressPercentage"] as? Double) ?? 0.0
                if pct < 100.0 {
                    currentSegmentIndex = i
                    break
                }
                currentSegmentIndex = i
            }
            
            let depIndex = currentSegmentIndex
            let arrIndex = min(depIndex + 1, max(0, allStops.count - 1))
            
            let distToDep = allStops.indices.contains(depIndex) ? distanceToStop(allStops[depIndex]) : 999999.0
            let distToArr = allStops.indices.contains(arrIndex) ? distanceToStop(allStops[arrIndex]) : 999999.0
            
            // Logique de positionnement
            var isStopped = false
            var stoppedAt = arrIndex
            
            if speed < 36 {
                if distToDep < 1500 {
                    isStopped = true
                    stoppedAt = depIndex
                } else if distToArr < 1500 {
                    isStopped = true
                    stoppedAt = arrIndex
                } else if currentLat == nil {
                    // Fallback si pas de GPS coord : utilisation de l'API
                    let depStop = allStops[depIndex]
                    let pDict = depStop["progress"] as? [String: Any]
                    let pct = (pDict?["progressPercentage"] as? Double) ?? 0.0
                    let remDistAPI = (pDict?["remainingDistance"] as? Double) ?? 999999.0
                    let travDistAPI = (pDict?["traveledDistance"] as? Double) ?? 999999.0
                    
                    if pct < 2.0 || travDistAPI < 1500 {
                        isStopped = true
                        stoppedAt = depIndex
                    } else if pct > 98.0 || remDistAPI < 1500 {
                        isStopped = true
                        stoppedAt = arrIndex
                    }
                }
            }
            
            isStoppedAtStation = isStopped
            // En mouvement, la "prochaine gare" est la gare d'arrivée du segment (arrIndex)
            nextStopIndex = isStopped ? stoppedAt : arrIndex

            if !allStops.isEmpty && allStops.indices.contains(nextStopIndex) {
                nextStopLabel = allStops[nextStopIndex]["label"] as? String
            }
        }

        // ── Titre icône de la barre des tâches ────────────────────────
        var barTitle = ""
        var customImage: NSImage? = nil
        var notificationDebug: [String: Any]?

        if !allStops.isEmpty {
            // Déterminer la gare d'arrivée cible
            var arrivalStationIndex = allStops.count - 1
            if let savedId = UserDefaults.standard.string(forKey: "arrivalStationId"),
               let idx = allStops.firstIndex(where: { ($0["id"] as? String) == savedId || ($0["label"] as? String) == savedId }) {
                if idx >= nextStopIndex {
                    arrivalStationIndex = idx
                }
            }
            let arrivalStop = allStops[arrivalStationIndex]
            let destLabel = arrivalStop["label"] as? String ?? ""
            
            // Calcul du temps estimé restant
            var timeRemainingStr = ""
            let dateStr = arrivalStop["realDate"] as? String ?? arrivalStop["theoricDate"] as? String
            if let targetDate = parseDate(dateStr), targetDate > Date() {
                let diffMins = Int(targetDate.timeIntervalSinceNow / 60)
                if diffMins >= 60 {
                    let h = diffMins / 60
                    let m = diffMins % 60
                    timeRemainingStr = m > 0 ? " \(h)h\(String(format: "%02d", m))" : " \(h)h"
                } else if diffMins > 0 {
                    timeRemainingStr = " \(diffMins)min"
                }
            }

            if let notificationTargetStop = notificationTargetStop(allStops: allStops,
                                                                   nextStopIndex: nextStopIndex,
                                                                   isStoppedAtStation: isStoppedAtStation,
                                                                   arrivalStationIndex: arrivalStationIndex) {
                let notifyLabel = notificationTargetStop["label"] as? String ?? "votre gare"
                let notifyId = (notificationTargetStop["id"] as? String) ?? notifyLabel
                let notifyDateStr = notificationTargetStop["realDate"] as? String ?? notificationTargetStop["theoricDate"] as? String
                if let notifyDate = parseDate(notifyDateStr) {
                    let notifyMins = Int(notifyDate.timeIntervalSinceNow / 60)
                    notificationDebug = [
                        "enabled": isBeforeArrivalNotificationEnabled,
                        "target": arrivalNotificationTarget.rawValue,
                        "targetStopId": notifyId,
                        "targetStopLabel": notifyLabel,
                        "minutesRemaining": notifyMins,
                        "leadTime": beforeArrivalNotificationLeadTime,
                        "isStoppedAtStation": isStoppedAtStation
                    ]
                    maybeNotifyBeforeArrival(
                        stopId: notifyId,
                        stopLabel: notifyLabel,
                        minutesRemaining: notifyMins,
                        isStoppedAtStation: isStoppedAtStation
                    )
                }
            }
            
            // Calcul de la progression basé sur le temps (départ → maintenant → arrivée cible)
            var globalProgress: Double = 0.0
            let firstStop = allStops[0]
            let firstDateStr = firstStop["realDate"] as? String ?? firstStop["theoricDate"] as? String
            let arrDateStr = arrivalStop["realDate"] as? String ?? arrivalStop["theoricDate"] as? String
            if let depDate = parseDate(firstDateStr), let arrDate = parseDate(arrDateStr), arrDate > depDate {
                let totalDuration = arrDate.timeIntervalSince(depDate)
                let elapsed = Date().timeIntervalSince(depDate)
                globalProgress = max(0.0, min(1.0, elapsed / totalDuration))
            }
            
            var text = ""
            if isStoppedAtStation, let station = nextStopLabel, !station.isEmpty {
                text = stationLocationText(shortStationName(station))
            } else {
                let shortDest = shortStationName(destLabel)
                if !timeRemainingStr.isEmpty {
                    // Priorité : nom de la gare + temps restant (ex. "Milano 1h05"), sans la vitesse.
                    text = shortDest.isEmpty
                        ? timeRemainingStr.trimmingCharacters(in: .whitespaces)
                        : "\(shortDest) ·\(timeRemainingStr)"
                } else {
                    text = shortDest
                }
            }
            
            // Mise en cache pour le redraw léger (clockTimer)
            cachedArrivalDate = parseDate(arrivalStop["realDate"] as? String ?? arrivalStop["theoricDate"] as? String)
            cachedDestShort = shortStationName(destLabel)
            cachedGlobalProgress = globalProgress
            cachedSpeed = speed
            cachedIsStopped = isStoppedAtStation
            cachedStoppedStation = nextStopLabel.map { shortStationName($0) } ?? ""
            cachedDelayMins = trainDelayMins
            cachedDelayCause = trainDelayCause

            customImage = StatusBarImageGenerator.draw(text: text, progress: globalProgress)
        } else {
            // Fallback s'il n'y a pas la liste des arrêts
            if let next = nextStopLabel {
                if isStoppedAtStation {
                    barTitle = stationLocationText(next)
                } else if speed > 0 {
                    barTitle = "\(speed) km/h  ›  \(next)"
                } else {
                    barTitle = "› \(next)"
                }
            } else if speed > 0 {
                barTitle = "\(speed) km/h"
            } else {
                barTitle = "inOui"
            }
        }

        // ── Sauvegarde des données brutes pour le mode Debug ────────────
        var rawData = debugSnapshotBase(operator: .sncf)
        if let g = gps { rawData["gps"] = g }
        if let d = details { rawData["details"] = d }
        if let b = bar { rawData["bar"] = b }
        if let s = stats { rawData["stats"] = s }
        if let st = status { rawData["status"] = st }
        if let n = notificationDebug { rawData["notification"] = n }
        self.lastRawData = rawData

        // ── Construction du modèle de vue pour le panneau SwiftUI ───────
        var viewState = TrainViewState(
            trainNumber: trainNumber,
            destination: destinationLabel,
            delayMin: trainDelayMins,
            delayCause: trainDelayCause,
            stops: [],
            globalProgress: cachedGlobalProgress,
            speedKmh: speed,
            wifiQuality: nil,
            wifiDevices: nil,
            dataConsumedMB: nil,
            dataTotalMB: nil,
            dataRemainingMB: nil,
            dataRatio: nil,
            dataResetTime: nil,
            arrivalOptions: [],
            selectedArrivalId: nil
        )

        // Desserte (timeline)
        viewState.stops = allStops.enumerated().map { (i, stop) -> StopRow in
            let lbl = (stop["label"] as? String) ?? "?"
            let delay = (stop["delay"] as? Int) ?? 0
            let status: StopStatus = i < nextStopIndex ? .passed : (i == nextStopIndex ? .current : .upcoming)
            return StopRow(
                id: (stop["id"] as? String) ?? "\(lbl)-\(i)",
                label: lbl,
                theoricTime: formatTime(stop["theoricDate"] as? String) ?? "",
                realTime: formatTime(stop["realDate"] as? String) ?? "",
                delayMin: delay,
                status: status
            )
        }

        // Qualité WiFi
        if let stats = stats {
            viewState.wifiQuality = stats["quality"] as? Int
            viewState.wifiDevices = stats["devices"] as? Int
        }

        // Consommation data
        if let status = status {
            let remaining = safeInt(status["remaining_data"])
            let consumed = safeInt(status["consumed_data"])
            let total = remaining + consumed
            if total > 0 {
                viewState.dataConsumedMB = Double(consumed) / 1000.0
                viewState.dataTotalMB = Double(total) / 1000.0
                viewState.dataRemainingMB = Double(remaining) / 1000.0
                viewState.dataRatio = max(0.0, min(1.0, Double(consumed) / Double(total)))
            }
            if let nextResetMs = asDouble(status["next_reset"]) {
                let resetDate = Date(timeIntervalSince1970: nextResetMs / 1000.0)
                viewState.dataResetTime = MenuBarController.resetTimeFormatter.string(from: resetDate)
            }
        }

        // Sélecteur de gare d'arrivée
        viewState.arrivalOptions = allStops.enumerated().map { (i, stop) -> ArrivalOption in
            let lbl = (stop["label"] as? String) ?? "Gare \(i)"
            return ArrivalOption(id: (stop["id"] as? String) ?? lbl, label: lbl)
        }
        let savedId = UserDefaults.standard.string(forKey: "arrivalStationId")
        let optionIds = viewState.arrivalOptions.map { $0.id }
        viewState.selectedArrivalId = savedId.flatMap { optionIds.contains($0) ? $0 : nil } ?? optionIds.last

        return (barTitle, customImage, viewState)
    }

    private func parseDate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: isoString) { return date }
        
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: isoString)
    }

    /// Convertit une date ISO 8601 en "HH:mm" heure locale.
    private func formatTime(_ isoString: String?) -> String? {
        guard let date = parseDate(isoString) else { return nil }
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        tf.timeZone = .current
        return tf.string(from: date)
    }

    // MARK: - Helpers de construction

    /// Articles qui font corps avec le nom de la gare : « Le Mans », « Les Aubrais », « La Roche ».
    private static let stationArticles: Set<String> = ["le", "la", "les", "l'"]

    private func stationLocationText(_ name: String) -> String {
        let station = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = station.lowercased()
        if lowercased.hasPrefix("le ") {
            return "En gare du \(station.dropFirst(3))"
        }
        if lowercased.hasPrefix("les ") {
            return "En gare des \(station.dropFirst(4))"
        }
        return "En gare de \(station)"
    }

    private func shortStationName(_ name: String) -> String {
        let exact: [String: String] = [
            "Paris - Gare de Lyon - Hall 1 & 2":                   "Paris Lyon",
            "Paris Montparnasse 1 Et 2":            "Montparnasse",
            "Paris Montparnasse":                   "Montparnasse",
            "Paris Gare du Nord":                   "Paris Nord",
            "Paris Saint-Lazare":                   "St-Lazare",
            "Paris Est":                            "Paris Est",
            "Marseille-Saint-Charles":              "Marseille",
            "Marseille Saint-Charles":              "Marseille",
            "Lyon Part-Dieu":                       "Lyon",
            "Lyon Perrache":                        "Lyon",
            "Bordeaux Saint-Jean":                  "Bordeaux",
            "Toulouse Matabiau":                    "Toulouse",
            "Lille Flandres":                       "Lille",
            "Montpellier Saint-Roch":               "Montpellier",
            "Nice Ville":                           "Nice",
            "Aix-en-Provence TGV":                  "Aix TGV",
            "Valence TGV Rhône-Alpes Sud":          "Valence TGV",
            "Aéroport Charles De Gaulle 2 Tgv":     "CDG TGV",
            "Charles De Gaulle 2 Tgv":              "CDG TGV",
            "Strasbourg Ville":                     "Strasbourg",
            "Marne-La-Vallée Chessy":               "Marne La Vallée",
        ]
        if let short = exact[name] { return short }
        if name.count <= 15 { return name }

        let words = name.split(separator: " ")
        // Nom long non répertorié : on garde le premier mot, qui est le plus souvent la ville
        // (ex. "Milano Porta Garibaldi" → "Milano", "Torino Porta Susa" → "Torino").
        // Quand ce premier mot est un article, il faut le suivant avec lui, sinon « Les Aubrais -
        // Orléans » se réduirait à « Les ».
        if let first = words.first {
            if Self.stationArticles.contains(first.lowercased()) {
                if words.count >= 2 { return "\(first) \(words[1])" }
            } else if first.count >= 3 {
                return String(first)
            }
        }

        // Troncature de dernier recours. On retire la ponctuation de fin, sans quoi une coupure au
        // milieu d'un nom composé laisse pendre un séparateur (« Les Aubrais - … »).
        let truncated = name.prefix(14).trimmingCharacters(in: CharacterSet(charactersIn: " -–—,'"))
        return truncated + "…"
    }

    // MARK: - Handlers

    @objc private func toggleDemoMode() {
        MockTrainData.shared.isEnabled.toggle()
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.start()
        } else {
            MockTrainData.shared.stop()
        }
        refresh()
    }

    @objc private func openDemoControlPanel() {
        guard let url = URL(string: MockTrainData.shared.baseURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // Les conversions sûres (`safeInt`, `asDouble`, `asBool`…) vivent dans ValueCoercion.swift,
    // partagées avec le builder d'état Eurostar.

    private var isBeforeArrivalNotificationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notifyBeforeArrivalEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyBeforeArrivalEnabledKey) }
    }

    private var beforeArrivalNotificationLeadTime: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: notifyBeforeArrivalMinutesKey)
            return allowedNotificationLeadTimes.contains(value) ? value : 10
        }
        set {
            let safeValue = allowedNotificationLeadTimes.contains(newValue) ? newValue : 10
            UserDefaults.standard.set(safeValue, forKey: notifyBeforeArrivalMinutesKey)
        }
    }

    private var lastKnownOperator: TrainOperator? {
        get {
            UserDefaults.standard.string(forKey: lastKnownOperatorKey)
                .flatMap(TrainOperator.init(rawValue:))
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: lastKnownOperatorKey) }
    }

    private var lastArrivalNotifiedStopId: String? {
        get { UserDefaults.standard.string(forKey: lastArrivalNotificationStopIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastArrivalNotificationStopIdKey) }
    }

    private var arrivalNotificationTarget: ArrivalNotificationTarget {
        get {
            guard let raw = UserDefaults.standard.string(forKey: notifyBeforeArrivalTargetKey),
                  let target = ArrivalNotificationTarget(rawValue: raw) else {
                return .selectedArrival
            }
            return target
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: notifyBeforeArrivalTargetKey)
        }
    }

    private func registerNotificationDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyBeforeArrivalEnabledKey: true,
            notifyBeforeArrivalMinutesKey: 10,
            notifyBeforeArrivalTargetKey: ArrivalNotificationTarget.selectedArrival.rawValue
        ])
    }

    private func currentSSIDInfo() -> (ssid: String, status: String) {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            return (ssid, "ok")
        }

        let auth = locationManager.authorizationStatus
        switch auth {
        case .notDetermined:
            return ("Inconnu", "location_not_determined")
        case .denied:
            return ("Inconnu", "location_denied")
        case .restricted:
            return ("Inconnu", "location_restricted")
        case .authorized, .authorizedAlways:
            if CWWiFiClient.shared().interface() == nil {
                return ("Inconnu", "wifi_interface_unavailable")
            }
            return ("Inconnu", "ssid_unavailable")
        @unknown default:
            return ("Inconnu", "unknown")
        }
    }

    private func requestSSIDAuthorizationIfNeeded() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        // La politique d'activation (.regular vs .accessory) est gérée dans main.swift
        // et AppDelegate selon le statut TCC au démarrage.
        locationManager.requestWhenInUseAuthorization()
    }

    private func notificationTargetStop(allStops: [[String: Any]],
                                        nextStopIndex: Int,
                                        isStoppedAtStation: Bool,
                                        arrivalStationIndex: Int) -> [String: Any]? {
        guard !allStops.isEmpty else { return nil }

        switch arrivalNotificationTarget {
        case .selectedArrival:
            return allStops.indices.contains(arrivalStationIndex) ? allStops[arrivalStationIndex] : nil
        case .nextStop:
            let index = isStoppedAtStation
                ? min(nextStopIndex + 1, allStops.count - 1)
                : nextStopIndex
            return allStops.indices.contains(index) ? allStops[index] : nil
        }
    }

    private func maybeNotifyBeforeArrival(stopId: String,
                                          stopLabel: String,
                                          minutesRemaining: Int,
                                          isStoppedAtStation: Bool) {
        guard isBeforeArrivalNotificationEnabled else { return }
        guard !isStoppedAtStation else { return }

        // Le train est arrivé ou a dépassé l'heure cible: on autorise les futures notifications.
        if minutesRemaining <= 0 {
            if lastArrivalNotifiedStopId == stopId {
                lastArrivalNotifiedStopId = nil
            }
            return
        }

        let leadTime = beforeArrivalNotificationLeadTime
        guard minutesRemaining <= leadTime else { return }
        guard lastArrivalNotifiedStopId != stopId else { return }

        let content = UNMutableNotificationContent()
        content.title = "Arrivée imminente"
        content.body = "Vous arrivez à \(stopLabel) dans environ \(minutesRemaining) min."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "arrival-\(stopId)", content: content, trigger: trigger)
        notificationCenter.add(request) { _ in }

        lastArrivalNotifiedStopId = stopId
    }

    // MARK: - Actions

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let url = URL(string: str) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAbout() {
        NSWorkspace.shared.open(URL(string: "https://github.com/antvgr/sncfwifi-macwidget")!)
    }

    @objc private func copyDebugData() {
        guard let data = lastRawData,
              let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonString, forType: .string)
    }
}

extension MenuBarController: NSPopoverDelegate {
    /// Filet de sécurité : la carte arrête déjà son sondage dans `onDisappear`, mais on ne laisse
    /// pas une requête par seconde tourner si SwiftUI ne le déclenchait pas à la fermeture.
    func popoverDidClose(_ notification: Notification) {
        mapModel.stop()
    }
}

extension MenuBarController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // Repasser en mode accessory (barre des menus, sans icône Dock) dans tous les cas,
        // que l'utilisateur ait accepté ou refusé.
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
        if status == .authorized || status == .authorizedAlways {
            refresh()
        }
    }
}
