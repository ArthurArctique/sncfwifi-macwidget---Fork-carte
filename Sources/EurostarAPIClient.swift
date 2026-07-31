import Foundation

/// Appelle en parallèle les endpoints de la plateforme Icomera utilisée par Eurostar.
///
/// Les réponses sont du JSONP (`({ … });`) : le déballage est assuré par `HTTPJSON`.
/// Contrairement à l'API SNCF, rien ici ne décrit le trajet (pas de numéro de train, de desserte,
/// de destination ni de retard) — uniquement position, connectivité, quota et fréquentation.
final class EurostarAPIClient {
    private let systemURL       = URL(string: "https://www.ombord.info/api/jsonp/system/")!
    private let connectivityURL = URL(string: "https://www.ombord.info/api/jsonp/connectivity/")!
    private let usersURL        = URL(string: "https://www.ombord.info/api/jsonp/users/")!
    private let userURL         = URL(string: "https://www.ombord.info/api/jsonp/user/")!
    private let positionURL     = URL(string: "https://www.ombord.info/api/jsonp/position/")!

    private let timeout: TimeInterval = 5

    /// Récupère toutes les infos en parallèle, notifie sur le main thread.
    func fetchAll(completion: @escaping (
        _ system: [String: Any]?,
        _ connectivity: [String: Any]?,
        _ users: [String: Any]?,
        _ user: [String: Any]?,
        _ position: [String: Any]?
    ) -> Void) {
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.fetchAllEurostar(completion: completion)
            return
        }

        let group = DispatchGroup()

        var systemData: [String: Any]?
        var connectivityData: [String: Any]?
        var usersData: [String: Any]?
        var userData: [String: Any]?
        var positionData: [String: Any]?

        group.enter()
        fetch(url: systemURL) { systemData = $0; group.leave() }

        group.enter()
        fetch(url: connectivityURL) { connectivityData = $0; group.leave() }

        group.enter()
        fetch(url: usersURL) { usersData = $0; group.leave() }

        group.enter()
        fetch(url: userURL) { userData = $0; group.leave() }

        group.enter()
        fetch(url: positionURL) { positionData = $0; group.leave() }

        group.notify(queue: .main) {
            completion(systemData, connectivityData, usersData, userData, positionData)
        }
    }

    private func fetch(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        HTTPJSON.fetchObject(url: url, timeout: timeout, completion: completion)
    }
}
