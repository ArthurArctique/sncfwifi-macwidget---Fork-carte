import Foundation

/// Récupération HTTP partagée par les clients embarqués (SNCF et Icomera/ombord).
///
/// L'API Eurostar sert du JSONP : le corps est enveloppé dans `(…);` — parfois précédé d'un nom
/// de callback. `JSONSerialization` refuse ce format, d'où le déballage préalable.
enum HTTPJSON {

    static let userAgent = "sncfwifi-macapp/1.0"
    static let defaultTimeout: TimeInterval = 5

    /// GET + décodage en objet JSON. `nil` en cas d'erreur réseau ou de corps non décodable.
    /// La complétion est appelée sur la file de `URLSession`, pas forcément le main thread.
    static func fetchObject(url: URL,
                            timeout: TimeInterval = defaultTimeout,
                            completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data else { completion(nil); return }
            completion(jsonObject(from: data))
        }.resume()
    }

    /// Décode un corps de réponse, qu'il soit du JSON nu (SNCF) ou du JSONP (ombord).
    static func jsonObject(from data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        guard let unwrapped = unwrapJSONP(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: unwrapped) as? [String: Any]
    }

    /// Extrait le premier objet JSON d'une enveloppe JSONP (`({…});`, `cb({…})`, …).
    ///
    /// On isole la sous-chaîne allant de la première `{` à la dernière `}`. C'est suffisant ici :
    /// les réponses ombord contiennent exactement un objet, et un scan de la structure complète
    /// serait de la sur-ingénierie face à des payloads figés par la plateforme.
    static func unwrapJSONP(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}
