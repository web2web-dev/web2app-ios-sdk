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

    /// Доступ по ЭТОЙ записи действует (статус active). `entitlement` отдаёт первую
    /// действующую запись ответа (WEB-2480).
    /// ⚠ Не различает тестовый/боевой грант — сверяйтесь с `testMode`.
    public var isActive: Bool { status == "active" }
}

private struct EntitlementResponse: Decodable {
    let guid: String
    let grants: [EntitlementGrant]
    let testMode: Bool

    enum CodingKeys: String, CodingKey { case guid, grants, testMode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guid = try c.decode(String.self, forKey: .guid)
        grants = try c.decode([EntitlementGrant].self, forKey: .grants)
        testMode = try c.decodeIfPresent(Bool.self, forKey: .testMode) ?? false
    }
}

/// WEB-2480 — ответ `entitlements`: все записи о доступе покупателя.
public struct Entitlements {
    /// guid, по которому спрашивали.
    public let guid: String
    /// Все записи в порядке сервера (новые вперёд), включая неактивные и записи
    /// соседних проектов той же организации — что открывать, приложение решает по
    /// своей карте `level` / `priceId`.
    public let grants: [EntitlementGrant]
    /// Признак тестового режима проекта у всего ответа (WEB-1166).
    public let testMode: Bool

    /// Первая действующая запись (как у `entitlement`), `nil` — действующих нет.
    public var activeGrant: EntitlementGrant? { grants.first { $0.isActive } }
}

/// WEB-2480 — почему `entitlements` не смог ответить. «Записей нет» — НЕ ошибка:
/// это успех с пустым `grants`. При `.network` / `.http` доступ не отнимайте —
/// спросите позже. В `switch` по этому типу держите общую ветку (`default:`):
/// в следующих версиях могут добавиться варианты.
public enum EntitlementsError: Error {
    /// `configure` не вызывался.
    case notConfigured
    /// guid ещё не сохранён (не было `identify` / показа страницы).
    case noGuid
    /// Нет ответа сервера (нет сети, обрыв, таймаут).
    case network(String)
    /// Сервер ответил кодом не 2xx.
    case http(Int)
    /// Ответ 2xx, но тело не разобрать.
    case badResponse
}

/// R1 passthrough — HTTP + декод + выбор записи для `entitlement` (WEB-2480).
struct EntitlementClient {
    let config: Web2AppConfig

    /// Разбор тела `/public/entitlement` → все записи в порядке сервера
    /// (новые вперёд); мусор → nil.
    static func parseGrants(_ data: Data) -> [EntitlementGrant]? {
        (try? JSONDecoder().decode(EntitlementResponse.self, from: data))?.grants
    }

    /// WEB-2480 п.1 — запись для `entitlement`: первая ДЕЙСТВУЮЩАЯ (`isActive`) в
    /// порядке сервера, а если действующих нет — самая новая (первая в ответе), как
    /// раньше. Раньше бралась только первая: свежая неактивная запись (возврат
    /// докупки, истёкшая) прятала действующую подписку. `isActive` не меняется.
    static func preferredGrant(_ grants: [EntitlementGrant]) -> EntitlementGrant? {
        grants.first { $0.isActive } ?? grants.first
    }

    /// WEB-2480 п.2 — различимый итог запроса права (чистая функция, без сети).
    static func classify(
        data: Data?, httpStatus: Int, networkError: Error?
    ) -> Result<Entitlements, EntitlementsError> {
        if let networkError {
            return .failure(.network(networkError.localizedDescription))
        }
        guard (200..<300).contains(httpStatus) else { return .failure(.http(httpStatus)) }
        guard
            let data,
            let decoded = try? JSONDecoder().decode(EntitlementResponse.self, from: data)
        else { return .failure(.badResponse) }
        return .success(
            Entitlements(guid: decoded.guid, grants: decoded.grants, testMode: decoded.testMode))
    }

    /// Запрос всех записей с различимой причиной отказа.
    func fetchAll(
        guid: String, completion: @escaping (Result<Entitlements, EntitlementsError>) -> Void
    ) {
        var comps = URLComponents(
            url: config.baseUrl.appendingPathComponent("public/entitlement"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard let url = comps?.url else { return completion(.failure(.badResponse)) }
        URLSession.shared.dataTask(with: url) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion(Self.classify(data: data, httpStatus: status, networkError: err))
        }.resume()
    }

    /// Разбор тела → запись для `entitlement` по `preferredGrant`; мусор → nil.
    static func parseGrant(_ data: Data) -> EntitlementGrant? {
        parseGrants(data).flatMap(preferredGrant)
    }

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
            guard let data, let grants = Self.parseGrants(data) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                SdkLogger.error(
                    "entitlement.decode_failed", context: ["http": String(code)])
                return completion(nil)
            }
            completion(Self.preferredGrant(grants))
        }.resume()
    }
}
