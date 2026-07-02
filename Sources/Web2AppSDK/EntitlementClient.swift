import Foundation

/// Право доступа — форма ответа R1 `GET /public/entitlement?guid=`.
/// Дословно зеркалит backend PublicEntitlementResponse (WEB-353/RESPONSE_EXAMPLE).
public struct EntitlementGrant: Decodable {
    public let level: String
    public let status: String          // "active" | "expired" | "revoked"
    public let expiresAt: String?      // ISO 8601 или nil (бессрочно)
    public let priceId: String?

    enum CodingKeys: String, CodingKey {
        case level, status
        case expiresAt = "expires_at"
        case priceId = "price_id"
    }

    /// Доступ действует, только если статус первого гранта = active.
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

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard
                let data,
                let decoded = try? JSONDecoder().decode(EntitlementResponse.self, from: data)
            else { return completion(nil) }
            // Право = первый грант (MVP-1: level == price_id, один активный грант).
            completion(decoded.grants.first)
        }.resume()
    }
}
