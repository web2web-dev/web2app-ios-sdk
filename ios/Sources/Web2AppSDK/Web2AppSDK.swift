import Foundation

/// web2app SDK — публичная поверхность (4 точки, Web2Wave-стиль). WEB-434.
///
/// Использование интегратором:
/// ```swift
/// Web2App.configure(projectId: "proj_...", baseUrl: URL(string: "https://api.example.com")!)
/// // при первом запуске — передать deep_link_value из СВОЕГО MMP-SDK (POC-1) ИЛИ nil:
/// Web2App.identify(deepLinkValue: afDeepLinkValue) { result in ... }
/// // затем в любой момент:
/// Web2App.entitlement { grant in if grant?.isActive == true { unlock() } }
/// ```
///
/// R1 (чтение права) НЕ тронут — `entitlement()` дословно проксирует
/// `GET /public/entitlement?guid=`. R2 = обвязка доставки guid перед R1.
public enum Web2App {
    private static var config: Web2AppConfig?
    private static let guidStore = GuidStore()

    // MARK: configure

    /// Инициализация. `projectId` = ключ проекта арендатора; `baseUrl` = наш API.
    public static func configure(projectId: String, baseUrl: URL) {
        config = Web2AppConfig(projectId: projectId, baseUrl: baseUrl)
    }

    // MARK: identify (guid-резолв первого запуска)

    /// Резолвит и персистит `guid`. Порядок (первый запуск):
    ///  1. Уже есть сохранённый guid (Keychain) → возвращаем его (steady-state).
    ///  2. `deepLinkValue` (из MMP-callback интегратора / Install Referrer) → resolve → guid. **[POC-1]**
    ///  3. Промах → email-fallback (caller показывает экран, затем `resolveEmail`). НЕ падаем молча.
    /// На успехе (любая ветка первого запуска) — шлём APP_INSTALLED-продюсер (best-effort).
    public static func identify(
        deepLinkValue: String?,
        completion: @escaping (Result<String, Web2AppError>) -> Void
    ) {
        guard let config else { return completion(.failure(.notConfigured)) }

        if let existing = guidStore.load() {
            return completion(.success(existing))
        }

        guard let token = deepLinkValue, !token.isEmpty else {
            // Промах MMP/referrer → caller обязан вызвать resolveEmail(...) (email-fallback).
            return completion(.failure(.needsEmailFallback))
        }

        AttributionResolver(config: config).resolveToken(token) { result in
            switch result {
            case .success(let guid):
                guidStore.save(guid)
                AppCallbackProducer(config: config).reportAppInstalled(guid: guid)
                completion(.success(guid))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// email-fallback: интегратор собрал email на своём экране → verified-resolve (WEB-431) → guid.
    public static func resolveEmail(
        _ email: String,
        completion: @escaping (Result<String, Web2AppError>) -> Void
    ) {
        guard let config else { return completion(.failure(.notConfigured)) }
        AttributionResolver(config: config).resolveEmail(email) { result in
            if case .success(let guid) = result {
                guidStore.save(guid)
                AppCallbackProducer(config: config).reportAppInstalled(guid: guid)
            }
            completion(result)
        }
    }

    // MARK: entitlement (R1 passthrough)

    /// Читает право по сохранённому guid — passthrough `GET /public/entitlement?guid=`.
    public static func entitlement(
        completion: @escaping (EntitlementGrant?) -> Void
    ) {
        guard let config, let guid = guidStore.load() else { return completion(nil) }
        EntitlementClient(config: config).fetch(guid: guid, completion: completion)
    }

    /// Текущий guid (если резолвлен). Client-held ключ — можно отдать хосту.
    public static func currentGuid() -> String? { guidStore.load() }
}

/// Конфиг SDK.
struct Web2AppConfig {
    let projectId: String
    let baseUrl: URL
}

/// Ошибки SDK.
public enum Web2AppError: Error {
    case notConfigured
    /// MMP/referrer промах — интегратор должен показать email-экран и вызвать `resolveEmail`.
    case needsEmailFallback
    case network(String)
    case resolveFailed
}
