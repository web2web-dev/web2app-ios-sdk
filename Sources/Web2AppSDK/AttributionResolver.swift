import Foundation

/// Резолв `guid` из carrier-token (атрибуционный диплинк / Install Referrer) или email.
///
/// ⚠ **Где лежит токен.** В ссылке, которую строит наш бэкенд, `deep_link_value` — это
/// КОНСТАНТА `handoff` (нейтральный UDL-роут, без полезной нагрузки), а сам опознавательный
/// токен лежит в **`deep_link_sub1`** и продублирован в **`af_sub1`** (Push API отбрасывает
/// произвольные имена параметров, но сохраняет `af_sub1..5`). Кто прочитает
/// `deep_link_value`, получит строку `handoff` — и опознание молча сломается.
///
/// ⚠ **POC-1 boundary:** SDK НЕ парсит внутренности MMP-SDK — интегратор сам достаёт токен
/// из СВОЕГО AppsFlyer/Adjust callback и отдаёт его в `Web2App.identify(deepLinkValue:)`.
/// POC-1 подтверждает, что MMP реально ДОСТАВЛЯЕТ этот токен на реальном iOS-девайсе
/// (adjust/ios_sdk#752, iOS17/18). До POC iOS-ветка ship-blocked — но код резолва токена
/// (ниже) POC-независим: как только token на руках, резолв в guid стабилен.
///
/// Интеграция MMP (talking-point для integration-doc):
/// ```swift
/// // AppsFlyer:
/// func onConversionDataSuccess(_ data: [AnyHashable: Any]) {
///     // токен в deep_link_sub1; af_sub1 — запасной слот того же значения
///     let token = (data["deep_link_sub1"] as? String) ?? (data["af_sub1"] as? String)
///     guard (data["af_status"] as? String) == "Non-organic",
///           (data["is_first_launch"] as? Bool) == true,
///           let token, !token.isEmpty else {
///         Web2App.identify(deepLinkValue: nil) { ... } // → email-fallback
///         return
///     }
///     Web2App.identify(deepLinkValue: token) { ... }
/// }
/// ```
struct AttributionResolver {
    let config: Web2AppConfig

    /// carrier-token → guid: `GET /public/handoff/resolve?code=<token>` (стабильный, WEB-433).
    ///
    /// Контракт ответа (проверено живым запросом к проду): успех = 200 с ОБЁРТКОЙ
    /// `{"success":true,"data":{"guid":"…","projectId":"…"}}`; неуспех (не найден / просрочен /
    /// уже использован) = 404 `{"message":…,"error":…,"statusCode":404}`. Плоское `{"guid":…}`
    /// поддерживаем на совместимость со старыми/иными окружениями — см. `parseGuidResponse`.
    func resolveToken(_ token: String, completion: @escaping (Result<String, Web2AppError>) -> Void) {
        var comps = URLComponents(
            url: config.baseUrl.appendingPathComponent("public/handoff/resolve"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "code", value: token)]
        guard let url = comps?.url else { return completion(.failure(.resolveFailed)) }
        Self.fetchGuid(url: url, method: "GET", body: nil, completion: completion)
    }

    /// email-recovery запрос (шаг 1): `POST /public/handoff/email-recovery/request`
    /// {projectId, email} → 204. Сервер шлёт magic-link; guid придёт на шаге 2, когда юзер
    /// откроет ссылку (code) → resolveToken. Контракт подтверждён: public-handoff.controller.
    func requestEmailRecovery(
        _ email: String,
        completion: @escaping (Result<Void, Web2AppError>) -> Void
    ) {
        let url = config.baseUrl.appendingPathComponent("public/handoff/email-recovery/request")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "projectId": config.projectId,
            "email": email,
        ])
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err {
                SdkLogger.error("email_recovery.network_error", err.localizedDescription)
                return completion(.failure(.network(err.localizedDescription)))
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) {
                SdkLogger.error("email_recovery.http_error", context: ["http": String(code)])
            }
            completion((200..<300).contains(code) ? .success(()) : .failure(.resolveFailed))
        }.resume()
    }

    /// Успешное тело в обёртке API: `{"success":true,"data":{"guid":…}}`.
    private struct GuidEnvelope: Decodable {
        struct Payload: Decodable { let guid: String }
        let data: Payload
    }

    /// Плоское тело `{"guid":…}` — совместимость со старыми/иными окружениями.
    private struct FlatGuidResponse: Decodable { let guid: String }

    /// Достаёт guid из тела ответа resolve: сперва обёртка `{data:{guid}}`, затем плоское
    /// `{guid}`. Тело ошибки, мусор, пустые данные и пустой guid → `nil` (наружу `.resolveFailed`).
    /// Internal (не публичный API) — точка для юнит-тестов разбора.
    static func parseGuidResponse(_ data: Data) -> String? {
        let decoder = JSONDecoder()
        let guid = (try? decoder.decode(GuidEnvelope.self, from: data))?.data.guid
            ?? (try? decoder.decode(FlatGuidResponse.self, from: data))?.guid
        guard let guid, !guid.isEmpty else { return nil }
        return guid
    }

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
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                SdkLogger.error("resolve.network_error", err.localizedDescription)
                return completion(.failure(.network(err.localizedDescription)))
            }
            guard let data, let guid = parseGuidResponse(data) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                SdkLogger.error("resolve.failed", context: ["http": String(code)])
                return completion(.failure(.resolveFailed))
            }
            completion(.success(guid))
        }.resume()
    }
}
