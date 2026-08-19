import Foundation

/// Право доступа — форма ответа R1 `GET /public/entitlement?guid=`.
/// Дословно зеркалит backend PublicEntitlementResponse (WEB-353/RESPONSE_EXAMPLE).
public struct EntitlementGrant: Decodable {
    public let level: String
    public let status: String          // "active" | "expired" | "revoked"
    public let expiresAt: String?      // ISO 8601 или nil (бессрочно)
    public let priceId: String?
    /// true ТОЛЬКО у синтетического гранта тестового режима проекта (WEB-1166):
    /// бэкенд помечает такие гранты `testMode: true`. Это НЕ настоящая оплата —
    /// не выдавайте боевой контент, если `testMode == true`, даже при
    /// `isActive == true`. Старые ответы без поля декодируются как false.
    public let testMode: Bool

    enum CodingKeys: String, CodingKey {
        case level, status, testMode
        case expiresAt = "expires_at"
        case priceId = "price_id"
    }

    init(
        level: String,
        status: String,
        expiresAt: String?,
        priceId: String?,
        testMode: Bool = false
    ) {
        self.level = level
        self.status = status
        self.expiresAt = expiresAt
        self.priceId = priceId
        self.testMode = testMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(String.self, forKey: .level)
        status = try c.decode(String.self, forKey: .status)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        priceId = try c.decodeIfPresent(String.self, forKey: .priceId)
        // Поле необязательное: боевые гранты приходят без него → false.
        testMode = try c.decodeIfPresent(Bool.self, forKey: .testMode) ?? false
    }

    /// Доступ действует, только если статус первого гранта = active.
    /// ⚠ Не различает тестовый/боевой грант — сверяйтесь с `testMode`.
    public var isActive: Bool { status == "active" }
}

private struct EntitlementResponse: Decodable {
    let guid: String
    let grants: [EntitlementGrant]
}

/// R1 passthrough. НЕ содержит логики права — только HTTP + декод.
struct EntitlementClient {
    let config: Web2AppConfig

    func fetch(guid: String, completion: @escaping (EntitlementGrant?) -> Void) {
        var comps = URLComponents(
            url: config.baseUrl.appendingPathComponent("public/entitlement"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard let url = comps?.url else { return completion(nil) }

        URLSession.shared.dataTask(with: url) { data, resp, err in
            if let err {
                SdkLogger.error("entitlement.network_error", err.localizedDescription)
                return completion(nil)
            }
            guard
                let data,
                let decoded = try? JSONDecoder().decode(EntitlementResponse.self, from: data)
            else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                SdkLogger.error(
                    "entitlement.decode_failed", context: ["http": String(code)])
                return completion(nil)
            }
            // Право = первый грант (MVP-1: level == price_id, один активный грант).
            completion(decoded.grants.first)
        }.resume()
    }
}
