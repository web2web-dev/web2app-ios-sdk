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

    /// email-fallback (WEB-431, ДВА шага — асинхронно):
    ///  (1) `requestEmailRecovery` → сервер шлёт magic-link на email (204). guid тут НЕ приходит.
    ///  (2) юзер открывает ссылку из письма → приложение получает `code` из deeplink →
    ///      `Web2App.identify(deepLinkValue: code)` резолвит guid (тот же resolve-путь).
    /// Контракт `POST /public/handoff/email-recovery/request` подтверждён в коде бэка.
    public static func requestEmailRecovery(
        _ email: String,
        completion: @escaping (Result<Void, Web2AppError>) -> Void
    ) {
        guard let config else { return completion(.failure(.notConfigured)) }
        AttributionResolver(config: config).requestEmailRecovery(email, completion: completion)
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

    // MARK: openWebPaywall (WEB-525 R2 — обратный флоу app→web-paywall)

    /// Показывает веб-пейвол органик-пользователю (пришёл в прилку НЕ через воронку) и
    /// возвращает право доступа после оплаты. Возврат-механика = **guid-поллинг** (ратиф.
    /// PM 2026-07-07): SDK кейит checkout на СВОЙ guid, после закрытия браузера поллит
    /// `entitlement()` по нему — БЕЗ resolve-by-email (тот S2S-HMAC, мобильному недоступен).
    ///
    /// `paywallURL` — URL опубликованного веб-пейвола (на кастом-домене клиента; наши
    /// apex/поддомены пейволы не отдают — WEB-395). `email` — опц. prefill из аккаунта
    /// прилки (юзер может поправить на вебе). `completion` — активный `EntitlementGrant`
    /// или `nil`, если за окно поллинга право не появилось (юзер закрыл/не оплатил).
    ///
    /// ⚠ MVP-1: сигнатура принимает готовый `paywallURL`. Серверный резолв
    /// `projectId → дефолт-пейвол-URL` (Adapty-плейсменты) — отдельный follow-up.
    public static func openWebPaywall(
        paywallURL: URL,
        email: String? = nil,
        completion: @escaping (EntitlementGrant?) -> Void
    ) {
        guard let config else { return completion(nil) }

        // guid-поллинг: берём client-held guid или чеканим новый (как web-visitorId),
        // персистим — grant на вебе ляжет на него, по нему же поллим entitlement.
        let guid = guidStore.load() ?? UUID().uuidString
        guidStore.save(guid)
        let url = WebPaywallLauncher.appOriginURL(paywallURL: paywallURL, email: email, guid: guid)

        #if canImport(UIKit) && canImport(SafariServices)
        let client = EntitlementClient(config: config)
        WebPaywallPresenter.present(url: url) {
            // Браузер закрыт → поллим право по нашему guid (Adapty getProfile-стиль):
            // 30 попыток × 2с ≈ 60с окна, покрывает Stripe webhook→grant задержку.
            WebPaywallLauncher.pollForActiveGrant(
                interval: 2.0,
                maxAttempts: 30,
                fetch: { cb in client.fetch(guid: guid, completion: cb) },
                completion: completion
            )
        }
        #else
        // Не-UIKit платформа (напр. macOS юнит-тесты): презентации нет — no-op.
        completion(nil)
        #endif
    }

    /// Открытие веб-пейвола ПО ID (SDK-трек PM 2026-07-24): интегратор знает
    /// только `paywallId` из кабинета — SDK резолвит публичный URL через
    /// `GET /public/paywall-url/:paywallId` (пейвол должен быть опубликован и
    /// привязан к домену; иначе 404 → completion(nil)) и открывает его
    /// существующим `openWebPaywall(paywallURL:)`-флоу (guid-поллинг,
    /// handleReturnURL — всё работает как обычно).
    public static func openWebPaywall(
        paywallId: String,
        email: String? = nil,
        completion: @escaping (EntitlementGrant?) -> Void
    ) {
        guard let config else { return completion(nil) }
        let resolveUrl = config.baseUrl
            .appendingPathComponent("public/paywall-url")
            .appendingPathComponent(paywallId)
        URLSession.shared.dataTask(with: resolveUrl) { data, _, _ in
            guard
                let data,
                let paywallURL = WebPaywallLauncher.parsePaywallUrlResponse(data)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async {
                openWebPaywall(
                    paywallURL: paywallURL, email: email, completion: completion)
            }
        }.resume()
    }

    // MARK: openWebPaywallEmbedded (WKWebView-режим с JS-мостом, 0.4.0)

    /// Показывает веб-пейвол во ВСТРОЕННОМ WKWebView с JS-мостом: при успехе
    /// оплаты пейвол закрывается АВТОМАТИЧЕСКИ (страница шлёт событие мосту),
    /// кнопка «Закрыть» тоже обрабатывается без URL-схемы. Результат
    /// типизирован (`PaywallResult`): paid / notPaid / pending — приложение
    /// сразу знает, запускать ли платный флоу или свои проверки.
    ///
    /// Отличие от `openWebPaywall(paywallURL:)` (Safari-режим): не требует
    /// регистрации URL-схемы; но страница живёт в вашем процессе (WKWebView).
    public static func openWebPaywallEmbedded(
        paywallURL: URL,
        email: String? = nil,
        completion: @escaping (PaywallResult) -> Void
    ) {
        guard let config else { return completion(.notPaid) }
        let guid = guidStore.load() ?? UUID().uuidString
        guidStore.save(guid)
        let url = WebPaywallLauncher.appOriginURL(
            paywallURL: paywallURL, email: email, guid: guid)

        #if canImport(UIKit) && canImport(WebKit)
        let client = EntitlementClient(config: config)
        WebViewPaywallPresenter.present(url: url) { event in
            // Успех с моста → грант уже записан (ранний грант на бэке) —
            // короткий поллинг добирает его; закрытие без успеха → быстрый
            // одиночный чек (вдруг оплатил, но событие не дошло).
            let attempts = event == .paymentSuccess ? 10 : 2
            WebPaywallLauncher.pollForActiveGrant(
                interval: 1.0,
                maxAttempts: attempts,
                fetch: { cb in client.fetch(guid: guid, completion: cb) }
            ) { grant in
                if let grant {
                    completion(.paid(grant))
                } else {
                    completion(event == .paymentSuccess ? .pending : .notPaid)
                }
            }
        }
        #else
        completion(.notPaid)
        #endif
    }

    /// Встроенный показ по paywallId — резолв URL той же публичной ручкой,
    /// затем `openWebPaywallEmbedded(paywallURL:)`.
    public static func openWebPaywallEmbedded(
        paywallId: String,
        email: String? = nil,
        completion: @escaping (PaywallResult) -> Void
    ) {
        guard let config else { return completion(.notPaid) }
        let resolveUrl = config.baseUrl
            .appendingPathComponent("public/paywall-url")
            .appendingPathComponent(paywallId)
        URLSession.shared.dataTask(with: resolveUrl) { data, _, _ in
            guard
                let data,
                let paywallURL = WebPaywallLauncher.parsePaywallUrlResponse(data)
            else {
                DispatchQueue.main.async { completion(.notPaid) }
                return
            }
            DispatchQueue.main.async {
                openWebPaywallEmbedded(
                    paywallURL: paywallURL, email: email, completion: completion)
            }
        }.resume()
    }

    // MARK: handleReturnURL (кнопка «Закрыть» на success-экране веб-пейвола)

    /// Обработчик возвратного deep-link'а из веб-пейвола: кнопка «Закрыть» на
    /// success-экране ведёт на `<схема-прилки>://handoff?code=...` (WEB-800).
    /// Интегратор: (1) регистрирует свою схему (CFBundleURLTypes) и указывает её
    /// в кабинете проекта (bridgeConfig.returnScheme); (2) зовёт этот метод из
    /// своего URL-обработчика (`application(_:open:)` / SceneDelegate
    /// `openURLContexts`) для ВСЕХ входящих URL — чужие вернут false.
    ///
    /// Что делает при распознавании: закрывает открытую шторку веб-пейвола —
    /// это триггерит уже существующий guid-поллинг права, и completion исходного
    /// `openWebPaywall` получает активный грант (юзер вернулся «уже платным»).
    /// `code` из ссылки намеренно НЕ консьюмится: доступ приходит по guid, а
    /// токен остаётся валидным для магик-линк письма.
    @discardableResult
    public static func handleReturnURL(_ url: URL) -> Bool {
        guard WebPaywallLauncher.isHandoffReturnURL(url) else { return false }
        #if canImport(UIKit) && canImport(SafariServices)
        WebPaywallPresenter.dismissActive()
        #endif
        return true
    }

    #if DEBUG
    /// DEBUG-only: инъекция guid для локального/симулятор-теста (реальной атрибуции на
    /// эмуляторе нет). В release-сборке компилируется ВОН — в проде недоступно.
    public static func debugSetGuid(_ guid: String) { guidStore.save(guid) }

    /// DEBUG-only: сброс сохранённого guid (для повторного прогона).
    public static func debugClear() { guidStore.clear() }
    #endif
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
