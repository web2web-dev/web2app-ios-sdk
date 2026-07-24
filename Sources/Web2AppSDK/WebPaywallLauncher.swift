import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(SafariServices)
import SafariServices
#endif

/// WEB-525 под-атом B — обратный флоу `openWebPaywall` (юзер в прилке → веб-пейвол → доступ).
///
/// Возврат-механика РАТИФИЦИРОВАНА PM (2026-07-07) = **guid-поллинг**, НЕ resolve-by-email
/// (тот S2S с HMAC — мобильному SDK секрет держать нельзя). Схема:
///   1. SDK берёт/генерит свой `guid` (client-held, Keychain).
///   2. Открывает веб-пейвол с `?origin=app&email=<e>&guid=<g>` в `SFSafariViewController`.
///      Веб-пейвол (под-атом A) кейит Stripe-checkout на этот guid → grant ложится на него.
///   3. После закрытия браузера прилка поллит `GET /public/entitlement?guid=g` (R1) до active.
///
/// Ниже — POC-независимое Foundation-ядро (сборка URL + поллинг-оркестрация), покрытое
/// юнит-тестами. Реальная презентация `SFSafariViewController` (iOS-only) — тонкая обвязка
/// под `#if canImport(UIKit)`, проверяется интегратором на девайсе (built≠works, L6).
enum WebPaywallLauncher {
    /// Чистая сборка app-origin URL: добавляет `origin=app` + опц. `email` + `guid`,
    /// СОХРАНЯЯ любой существующий query исходного URL пейвола.
    static func appOriginURL(paywallURL: URL, email: String?, guid: String) -> URL {
        var comps =
            URLComponents(url: paywallURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "origin", value: "app"))
        if let email, !email.isEmpty {
            items.append(URLQueryItem(name: "email", value: email))
        }
        items.append(URLQueryItem(name: "guid", value: guid))
        comps.queryItems = items
        return comps.url ?? paywallURL
    }

    /// Открытие по paywallId (SDK-трек PM 2026-07-24): парсинг ответа
    /// `GET /public/paywall-url/:paywallId` → URL опубликованного пейволла.
    /// Мусор/404-тело → nil (совместимо с anti-enum бэка).
    static func parsePaywallUrlResponse(_ data: Data) -> URL? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let payload = obj["data"] as? [String: Any],
            let urlString = payload["url"] as? String,
            let url = URL(string: urlString)
        else { return nil }
        return url
    }

    /// Возвратный deep-link кнопки «Закрыть» на success-экране (WEB-800):
    /// контракт `<схема-прилки>://handoff?code=...` → распознаём по host == "handoff",
    /// схему не проверяем (она клиентская и SDK неизвестна).
    static func isHandoffReturnURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "handoff"
    }

    /// Поллит `fetch` каждые `interval` секунд до `maxAttempts` попыток. Останавливается и
    /// отдаёт грант, как только он `isActive`; отдаёт `nil`, если active-грант не появился в
    /// бюджете попыток. `fetch` инъектируется (сеть/тест) — сама оркестрация POC-независима.
    static func pollForActiveGrant(
        interval: TimeInterval,
        maxAttempts: Int,
        fetch: @escaping (@escaping (EntitlementGrant?) -> Void) -> Void,
        completion: @escaping (EntitlementGrant?) -> Void
    ) {
        guard maxAttempts > 0 else { return completion(nil) }
        func attempt(_ n: Int) {
            fetch { grant in
                if let grant, grant.isActive {
                    completion(grant)
                } else if n + 1 >= maxAttempts {
                    completion(nil)
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                        attempt(n + 1)
                    }
                }
            }
        }
        attempt(0)
    }
}

#if canImport(UIKit) && canImport(SafariServices)
/// iOS-презентер веб-пейвола в `SFSafariViewController`. Тонкая обёртка (не покрыта
/// swift-test — UIKit/Safari только на девайсе/симуляторе). Держит делегат живым, пока
/// экран открыт; вызывает `onDismiss`, когда пользователь закрывает браузер.
final class WebPaywallPresenter: NSObject, SFSafariViewControllerDelegate {
    private var retained: WebPaywallPresenter?
    private let onDismiss: () -> Void
    private weak var safari: SFSafariViewController?
    private var finished = false

    /// Последний открытый веб-пейвол — для программного закрытия по возвратному
    /// deep-link'у (`Web2App.handleReturnURL`). weak: presenter self-owning до finish.
    private static weak var active: WebPaywallPresenter?

    private init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    /// Открывает `url` в SFSafariViewController поверх верхнего view controller.
    static func present(url: URL, onDismiss: @escaping () -> Void) {
        let presenter = WebPaywallPresenter(onDismiss: onDismiss)
        presenter.retained = presenter // удержать до dismiss (self-owning)

        let safari = SFSafariViewController(url: url)
        safari.delegate = presenter
        presenter.safari = safari

        guard let top = Self.topViewController() else {
            // Нет UI-контекста — сразу отдаём управление (прилка сама решит).
            presenter.retained = nil
            onDismiss()
            return
        }
        Self.active = presenter
        top.present(safari, animated: true)
    }

    /// Программно закрывает активную шторку веб-пейвола (возврат по кнопке
    /// «Закрыть» на success-экране). `finish()` дергает onDismiss → стартует
    /// немедленный guid-поллинг права. Возвращает false, если шторки нет.
    @discardableResult
    static func dismissActive() -> Bool {
        guard let presenter = active else { return false }
        if let safari = presenter.safari, safari.presentingViewController != nil {
            safari.dismiss(animated: true) { presenter.finish() }
        } else {
            presenter.finish()
        }
        return true
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        finish()
    }

    /// Единая точка завершения: onDismiss строго один раз (юзер закрыл шторку
    /// сам ИЛИ её закрыл handleReturnURL — не оба).
    private func finish() {
        guard !finished else { return }
        finished = true
        onDismiss()
        if Self.active === self { Self.active = nil }
        retained = nil // отпустить self после закрытия
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let keyWindow =
            scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif
