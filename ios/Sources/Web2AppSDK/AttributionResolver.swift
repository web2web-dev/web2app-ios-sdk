import Foundation

/// Резолв `guid` из carrier-token (deep_link_value / Install Referrer) или email.
///
/// ⚠ **POC-1 boundary:** SDK НЕ парсит внутренности MMP-SDK — интегратор передаёт готовый
/// `deep_link_value` из СВОЕГО AppsFlyer/Adjust callback в `Web2App.identify(deepLinkValue:)`.
/// POC-1 подтверждает, что MMP реально ДОСТАВЛЯЕТ `deep_link_value` на реальном iOS-девайсе
/// (adjust/ios_sdk#752, iOS17/18). До POC iOS-ветка ship-blocked — но код резолва токена
/// (ниже) POC-независим: как только token на руках, резолв в guid стабилен.
///
/// Интеграция MMP (talking-point для integration-doc):
/// ```swift
/// // AppsFlyer:
/// func onConversionDataSuccess(_ data: [AnyHashable: Any]) {
///     guard (data["af_status"] as? String) == "Non-organic",
///           (data["is_first_launch"] as? Bool) == true,
///           let token = data["deep_link_value"] as? String else {
///         Web2App.identify(deepLinkValue: nil) { ... } // → email-fallback
///         return
///     }
///     Web2App.identify(deepLinkValue: token) { ... }
/// }
/// ```
struct AttributionResolver {
    let config: Web2AppConfig

    /// carrier-token → guid: `GET /public/handoff/resolve?code=<token>` (стабильный, WEB-433).
    func resolveToken(_ token: String, completion: @escaping (Result<String, Web2AppError>) -> Void) {
        var comps = URLComponents(
            url: config.baseUrl.appendingPathComponent("public/handoff/resolve"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "code", value: token)]
        guard let url = comps?.url else { return completion(.failure(.resolveFailed)) }
        Self.fetchGuid(url: url, method: "GET", body: nil, completion: completion)
    }

    /// email-fallback → verified-resolve → guid.
    /// ⚠ Зависит от WEB-431 (email-ядро, In Review): точный контракт recovery request/verify
    /// финализируется при мёрдже 431. Здесь — целевая форма (POST verify → { guid }).
    func resolveEmail(_ email: String, completion: @escaping (Result<String, Web2AppError>) -> Void) {
        let url = config.baseUrl.appendingPathComponent("public/handoff/email-recovery/verify")
        let body = try? JSONSerialization.data(withJSONObject: [
            "projectId": config.projectId,
            "email": email,
        ])
        Self.fetchGuid(url: url, method: "POST", body: body, completion: completion)
    }

    private struct GuidResponse: Decodable { let guid: String }

    private static func fetchGuid(
        url: URL,
        method: String,
        body: Data?,
        completion: @escaping (Result<String, Web2AppError>) -> Void
    ) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err { return completion(.failure(.network(err.localizedDescription))) }
            guard
                let data,
                let decoded = try? JSONDecoder().decode(GuidResponse.self, from: data),
                !decoded.guid.isEmpty
            else { return completion(.failure(.resolveFailed)) }
            completion(.success(decoded.guid))
        }.resume()
    }
}
