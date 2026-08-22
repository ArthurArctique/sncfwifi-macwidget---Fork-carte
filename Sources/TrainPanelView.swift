import SwiftUI
import AppKit
import Combine

/// Largeur fixe du panneau (style Centre de contrôle).
private let panelWidth: CGFloat = 300

extension NSColor {
    /// Carmillon — couleur de marque SNCF / TGV INOUI (#7D206F). Déclaré ici plutôt qu'en `Color`
    /// parce que MapKit (tracé du trajet, marqueurs) travaille en `NSColor`.
    static let carmillon = NSColor(srgbRed: 125.0 / 255.0, green: 32.0 / 255.0, blue: 111.0 / 255.0, alpha: 1)
}

extension Color {
    static let carmillon = Color(NSColor.carmillon)

    /// Bleu Eurostar. Le bleu nuit de marque (#001A5E) se confond avec le fond en mode sombre,
    /// d'où une variante éclaircie fournie dynamiquement par l'apparence système.
    static let eurostarBlue = Color(NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 107.0 / 255.0, green: 153.0 / 255.0, blue: 1.0, alpha: 1.0)
            : NSColor(srgbRed: 0.0, green: 26.0 / 255.0, blue: 94.0 / 255.0, alpha: 1.0)
    })
}

extension TrainOperator {
    /// Couleur d'accent du panneau, par opérateur.
    var accent: Color {
        switch self {
        case .sncf:     return .carmillon
        case .eurostar: return .eurostarBlue
        }
    }

    /// Logo de marque déposé dans `Resources/Logos/`, `nil` si le fichier est absent.
    ///
    /// Convention : `logo-<rawValue>.png` (+ `@2x`), et `logo-<rawValue>-dark.png` pour une
    /// variante mode sombre facultative. Ajouter une compagnie se limite donc à ajouter un cas à
    /// `TrainOperator` et à déposer le fichier — aucun code à écrire. Les logos étant des marques
    /// déposées, leur absence est un cas normal : l'en-tête retombe alors sur l'icône générique.
    func logo(dark: Bool) -> NSImage? {
        if dark, let variant = NSImage(named: "logo-\(rawValue)-dark") { return variant }
        return NSImage(named: "logo-\(rawValue)")
    }
}

/// Mise en forme du dénivelé positif, partagée par la timeline et la ligne de résumé.
enum ElevationLabel {
    /// "280 m", "1,6 km" au-delà du millier — l'unité bascule comme pour les volumes de données.
    static func gain(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.1f km", locale: .current, meters / 1000)
            : String(format: "%.0f m", locale: .current, meters)
    }
}

// MARK: - Vue racine

struct TrainPanelView: View {
    @EnvironmentObject var store: TrainStore
    @EnvironmentObject var mapModel: TrainMapModel

    var body: some View {
        // La carte prend toute la place du popover : c'est une bascule, pas une fenêtre à part.
        if store.showsMap, case .connected(let state) = store.state {
            TrainMapView(model: mapModel,
                         accent: state.operatorKind.accent,
                         onBack: { store.showsMap = false })
        } else {
            VStack(spacing: 0) {
                switch store.state {
                case .loading:
                    LoadingView()
                case .notConnected(let demoMode):
                    NotConnectedView(demoMode: demoMode)
                case .connected(let state):
                    ConnectedView(state: state)
                }
                Divider()
                FooterView()
            }
            .frame(width: panelWidth)
        }
    }
}

// MARK: - États simples

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Chargement…")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct NotConnectedView: View {
    @EnvironmentObject var store: TrainStore
    let demoMode: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: demoMode ? "network.slash" : "wifi.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.secondary)

            if demoMode {
                Text("Serveur démo indisponible")
                    .font(.headline)
                Text("Démarre-le avec ./start_demo_server.sh")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Ouvrir le panneau démo") { store.onOpenDemoPanel() }
            } else {
                Text("Non connecté au WiFi d'un train")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("SNCF inOui ou Eurostar (ou API du train indisponible)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
    }
}

// MARK: - Contenu train connecté

private struct ConnectedView: View {
    @EnvironmentObject var store: TrainStore
    let state: TrainViewState

    private var accent: Color { state.operatorKind.accent }

    /// Vrai dès qu'une des sections « réseau » a de quoi s'afficher.
    private var hasNetworkSection: Bool {
        state.wifiQuality != nil
            || state.wifiDevices != nil
            || state.dataConsumedMB != nil
            || state.activeModemCount != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderView(state: state, accent: accent)

                if state.operatorKind == .sncf {
                    Button {
                        store.showsMap = true
                    } label: {
                        Label("Carte du trajet", systemImage: "map.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(accent)

                    Button {
                        store.onToggleElevation()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.circle.fill")
                            Text(store.showsElevation ? "Masquer le dénivelé" : "Dénivelé du trajet")
                            Spacer()
                            if store.isLoadingElevation {
                                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(accent)
                    .help("Calcule le dénivelé positif du trajet auprès du RGE ALTI de l'IGN")
                }

                if !state.stops.isEmpty {
                    Divider()
                    TimelineView(stops: state.stops, accent: accent)
                }

                if let current = state.currentElevationGainM {
                    Divider()
                    ElevationView(current: current, total: state.totalElevationGainM, accent: accent)
                }

                if hasNetworkSection {
                    Divider()
                    if state.wifiQuality != nil || state.wifiDevices != nil {
                        WifiView(quality: state.wifiQuality, devices: state.wifiDevices, accent: accent)
                    }
                    if state.activeModemCount != nil {
                        ConnectivityView(state: state, accent: accent)
                    }
                    if state.dataConsumedMB != nil {
                        DataView(state: state, accent: accent)
                    }
                }

                RefreshStatusView()
                    .padding(.top, 2)
            }
            .padding(16)
        }
        .frame(maxHeight: 460)
    }
}

// MARK: - En-tête

private struct HeaderView: View {
    let state: TrainViewState
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    /// Hauteur de rendu du logo, calée sur celle de l'icône `tram.fill` qu'il remplace.
    private let logoHeight: CGFloat = 20

    private var logo: NSImage? {
        state.operatorKind.logo(dark: colorScheme == .dark)
    }

    /// Quand le logo porte déjà l'identité de la compagnie, seul le numéro de train subsiste —
    /// et Eurostar n'en expose aucun, l'en-tête se réduit alors au logo.
    /// Sans logo, on garde le libellé complet : "TGV INOUI n° 6201" / "Eurostar".
    private var title: String? {
        let number = state.trainNumber.flatMap { $0.isEmpty ? nil : $0 }
        guard logo == nil else { return number.map { "n° \($0)" } }
        let name = state.operatorKind.displayName
        return number.map { "\(name) n° \($0)" } ?? name
    }

    /// Destination pour SNCF, nom de la rame pour Eurostar (seule identité disponible).
    private var subtitle: String? {
        if let dest = state.destination, !dest.isEmpty { return "→ \(dest)" }
        if let rame = state.rameName, !rame.isEmpty { return rame }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if let logo = logo {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: logoHeight)
                        // Le nom disparaît du texte : on le conserve pour VoiceOver.
                        .accessibilityLabel(state.operatorKind.displayName)
                } else {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 18))
                        .foregroundColor(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let title = title {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if state.speedKmh > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .foregroundColor(accent)
                        Text("\(state.speedKmh) km/h")
                            .foregroundColor(.primary)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
                }
            }

            if state.delayMin > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(delayText)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
    }

    private var delayText: String {
        var t = "Retard +\(state.delayMin) min"
        if !state.delayCause.isEmpty { t += " · \(state.delayCause)" }
        return t
    }
}

// MARK: - Timeline des arrêts

private struct TimelineView: View {
    let stops: [StopRow]
    let accent: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                StopRowView(stop: stop,
                            accent: accent,
                            isFirst: index == 0,
                            isLast: index == stops.count - 1)
            }
        }
    }
}

private struct StopRowView: View {
    let stop: StopRow
    let accent: Color
    let isFirst: Bool
    let isLast: Bool

    private var dotColor: Color {
        switch stop.status {
        case .passed:   return accent
        case .current:  return accent
        case .upcoming: return .secondary
        }
    }

    private var symbol: String {
        switch stop.status {
        case .passed:   return "checkmark.circle.fill"
        case .current:  return "record.circle.fill"
        case .upcoming: return "circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Colonne rail + pastille
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .padding(.top, isFirst ? 9 : 0)
                    .padding(.bottom, isLast ? 9 : 0)
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(dotColor)
            }
            .frame(width: 18)

            // Libellé + horaires
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stop.label)
                        .font(.system(size: 12, weight: stop.status == .current ? .semibold : .regular))
                        .foregroundColor(stop.status == .upcoming ? .secondary : .primary)
                    if let gain = stop.elevationGainM, !isFirst {
                        Label(ElevationLabel.gain(gain), systemImage: "arrow.up.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .help("Dénivelé positif cumulé depuis le départ")
                    }
                }
                Spacer(minLength: 4)
                if stop.delayMin > 0 && !stop.theoricTime.isEmpty && stop.theoricTime != stop.realTime {
                    Text(stop.theoricTime)
                        .strikethrough()
                        .foregroundColor(.secondary)
                    Text(stop.realTime)
                        .foregroundColor(.orange)
                } else if !stop.realTime.isEmpty {
                    Text(stop.realTime)
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.bottom, isLast ? 0 : 12)
        }
    }
}

// MARK: - Dénivelé

private struct ElevationView: View {
    let current: Double
    let total: Double?
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(accent)
            Text("Dénivelé positif")
                .font(.system(size: 12))
            Spacer()
            Text(ElevationLabel.gain(current))
                .font(.system(size: 12, weight: .semibold))
            if let total, total > current {
                Text("/ \(ElevationLabel.gain(total))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .help("Cumul depuis la gare de départ. Estimation à partir du RGE ALTI de l'IGN, lissée sur 2 km.")
    }
}

// MARK: - Qualité WiFi

private struct WifiView: View {
    /// Absente côté Eurostar : la qualité radio y est détaillée par `ConnectivityView`.
    let quality: Int?
    let devices: Int?
    let accent: Color

    var body: some View {
        HStack(spacing: 16) {
            MetricPill(symbol: symbol, text: wifiText, tint: tint)
            Spacer(minLength: 0)
        }
    }

    private var isDegraded: Bool {
        guard let quality else { return false }
        return quality < 3
    }

    private var symbol: String { isDegraded ? "wifi.exclamationmark" : "wifi" }
    private var tint: Color { isDegraded ? .orange : accent }

    private var wifiText: String {
        var parts: [String] = []
        if let quality { parts.append("WiFi \(quality)/5") }
        if let devices { parts.append("\(devices) pers.") }
        return parts.joined(separator: " · ")
    }
}

private struct MetricPill: View {
    let symbol: String
    let text: String
    var tint: Color = .carmillon

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundColor(tint)
            Text(text).foregroundColor(.primary)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

// MARK: - Connectivité sol↔train (plateforme Icomera / Eurostar)

/// Détail des liaisons montantes : la rame agrège plusieurs modems cellulaires, chacun sur un
/// opérateur différent. L'API SNCF n'expose rien d'équivalent, cette section reste donc masquée
/// à bord d'un TGV.
private struct ConnectivityView: View {
    let state: TrainViewState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundColor(tint)
                Text(headline).foregroundColor(.primary)
            }
            .font(.system(size: 12, weight: .medium))

            if let detail = signalDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if !state.modemOperators.isEmpty {
                Text(state.modemOperators.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let mbps = state.bandwidthDownMbps {
                Text(String(format: "Débit max %.0f Mbit/s", mbps))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var isOffline: Bool { state.isOnline == false }

    private var symbol: String {
        if isOffline { return "antenna.radiowaves.left.and.right.slash" }
        return "antenna.radiowaves.left.and.right"
    }

    private var tint: Color {
        if isOffline { return .orange }
        if let quality = state.signalQuality, quality < 3 { return .orange }
        return accent
    }

    private var headline: String {
        if isOffline { return "Liaison sol interrompue" }

        var parts: [String] = []
        parts.append(state.linkTechnology.map { "Réseau \($0)" } ?? "Liaison mobile")
        if let count = state.activeModemCount, count > 0 {
            parts.append(count > 1 ? "\(count) modems actifs" : "1 modem actif")
        }
        return parts.joined(separator: " · ")
    }

    private var signalDetail: String? {
        var parts: [String] = []
        if let rssi = state.signalRSSI { parts.append("Signal \(rssi) dBm") }
        if let quality = state.signalQuality { parts.append("\(quality)/5") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Consommation data

private struct DataView: View {
    let state: TrainViewState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Données", systemImage: "arrow.up.arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let ratio = state.dataRatio {
                    Text("\(Int((ratio * 100).rounded())) %")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            // Sans quota connu, on affiche le volume consommé sans jauge.
            if let ratio = state.dataRatio {
                ProgressView(value: min(max(ratio, 0), 1))
                    .accentColor(ratio > 0.85 ? .red : accent)
            }
            if let line = usageLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// "16,9 Mo / 1,0 Go utilisés · reset 14:05" — les unités s'adaptent au volume, les deux
    /// plateformes n'ayant pas du tout les mêmes ordres de grandeur de quota.
    private var usageLine: String? {
        guard let consumed = state.dataConsumedMB else { return nil }

        var t: String
        if let total = state.dataTotalMB {
            t = "\(DataVolume.label(consumed)) / \(DataVolume.label(total)) utilisés"
        } else {
            t = "\(DataVolume.label(consumed)) utilisés"
        }
        if let reset = state.dataResetTime { t += " · reset \(reset)" }
        if let timeLeft = state.dataTimeLeft { t += " · reste \(timeLeft)" }
        return t
    }
}

// MARK: - Indicateur discret d'actualisation

private struct RefreshStatusView: View {
    @EnvironmentObject var store: TrainStore
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    var body: some View {
        HStack {
            Spacer()
            if let text = statusText {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(0.7))
            }
            Spacer()
        }
        .onReceive(ticker) { now = $0 }
    }

    private var statusText: String? {
        guard let last = store.lastRefreshDate else { return nil }
        let elapsed = now.timeIntervalSince(last)
        let remaining = max(0, Int((store.refreshInterval - elapsed).rounded()))
        return "Actualisé à \(RefreshStatusView.timeFormatter.string(from: last)) · prochaine dans \(remaining) s"
    }
}

// MARK: - Pied de page (actions + réglages + debug)

private struct FooterView: View {
    @EnvironmentObject var store: TrainStore

    @AppStorage("notifyBeforeArrivalEnabled") private var notifyEnabled = true
    @AppStorage("notifyBeforeArrivalMinutes") private var notifyMinutes = 10
    @AppStorage("notifyBeforeArrivalTarget") private var notifyTarget = "selectedArrival"
    @AppStorage("isDemoMode") private var demoMode = false
    @AppStorage("demoOperator") private var demoOperator = TrainOperator.sncf.rawValue

    private let leadTimes = [5, 10, 15]

    var body: some View {
        HStack(spacing: 4) {
            footerButton("arrow.2.circlepath", help: "Actualiser") { store.onRefresh() }

            settingsMenu
            debugMenu

            Spacer()

            footerButton("info.circle", help: "À propos") { store.onOpenAbout() }
            footerButton("power", help: "Quitter") { store.onQuit() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Options de gare d'arrivée, disponibles uniquement quand un train est connecté.
    private var arrival: (options: [ArrivalOption], selectedId: String?)? {
        if case let .connected(state) = store.state, !state.arrivalOptions.isEmpty {
            return (state.arrivalOptions, state.selectedArrivalId)
        }
        return nil
    }

    /// Les réglages d'arrivée n'ont de sens que si l'opérateur fournit une desserte : la
    /// plateforme Eurostar n'expose aucun horaire, on masque donc ces entrées à bord.
    private var supportsArrivalNotifications: Bool {
        if case let .connected(state) = store.state { return !state.arrivalOptions.isEmpty }
        // Hors connexion, on laisse l'utilisateur régler ses préférences.
        return true
    }

    private var settingsMenu: some View {
        Menu {
            if let arrival = arrival {
                Menu("Gare d'arrivée") {
                    ForEach(arrival.options) { option in
                        Button {
                            store.onSelectArrival(option.id)
                        } label: {
                            checkLabel(option.label, on: option.id == arrival.selectedId)
                        }
                    }
                }
                Divider()
            }

            if supportsArrivalNotifications {
                Button {
                    notifyEnabled.toggle()
                    store.onSettingsChanged()
                } label: {
                    checkLabel("Notification avant arrivée", on: notifyEnabled)
                }

                Menu("Délai de notification") {
                    ForEach(leadTimes, id: \.self) { minutes in
                        Button {
                            notifyMinutes = minutes
                            store.onSettingsChanged()
                        } label: {
                            checkLabel("\(minutes) min", on: notifyMinutes == minutes)
                        }
                    }
                }

                Menu("Type de notification") {
                    Button {
                        notifyTarget = "selectedArrival"
                        store.onSettingsChanged()
                    } label: {
                        checkLabel("Gare d'arrivée sélectionnée", on: notifyTarget == "selectedArrival")
                    }
                    Button {
                        notifyTarget = "nextStop"
                        store.onSettingsChanged()
                    } label: {
                        checkLabel("Prochaine gare", on: notifyTarget == "nextStop")
                    }
                }
            } else {
                Text("Aucun horaire fourni par cet opérateur")
            }
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .fixedSize()
        .help("Réglages")
    }

    private var debugMenu: some View {
        Menu {
            Button {
                store.onToggleDemo()
            } label: {
                checkLabel("Mode Démo (serveur local)", on: demoMode)
            }
            Menu("Opérateur simulé") {
                ForEach(TrainOperator.allCases, id: \.rawValue) { op in
                    Button {
                        store.onSetDemoOperator(op)
                    } label: {
                        checkLabel(op.displayName, on: demoOperator == op.rawValue)
                    }
                }
            }
            Button("Ouvrir le panneau démo") { store.onOpenDemoPanel() }
            Divider()
            Button {
                store.onCopyJSON()
            } label: {
                Label("Copier le JSON", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ladybug.fill")
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .fixedSize()
        .help("Debug")
    }

    @ViewBuilder
    private func checkLabel(_ title: String, on: Bool) -> some View {
        if on {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
    }
}
