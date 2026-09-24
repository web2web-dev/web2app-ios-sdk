import Foundation

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
#endif

/// Предзагрузка встроенных пейволов (0.8.0): страница грузится в фоновом
/// WKWebView ЗАРАНЕЕ, а показ берёт готовый инстанс — без белого экрана на
/// время резолва URL и загрузки.
///
/// Ниже — POC-независимое Foundation-ядро (параметры, правило переиспользования,
/// контракт с вебом), покрытое юнитами. UIKit-кэш WebView — `PaywallPreloader`.
enum PaywallPreload {
    /// КОНТРАКТ с вебом. Предзагруженная страница открыта с `?preload=1` и НЕ
    /// должна слать `PAYWALL_VIEW` и ставить пиксели, пока её не показали:
    /// иначе каждый фоновый инстанс — просмотр, которого не было.
    static let paramPreload = "preload"

    /// КОНТРАКТ с вебом. Момент реального показа SDK сообщает странице так:
    /// флаг `window.__web2appShown = true` (страница, дочитавшая скрипты позже,
    /// проверит его при старте) + событие `web2app:shown` на `window`.
    /// Сигнал может прийти ДВАЖДЫ (показали до конца загрузки → повтор после
    /// неё) — дедупликация на стороне страницы.
    static let shownScript =
        "window.__web2appShown = true;"
        + "window.dispatchEvent(new Event('web2app:shown'));"

    /// Сколько живёт предзагруженная страница. Старше — показываем свежую:
    /// за час пейвол могли перепубликовать (цены, тексты).
    static let maxAge: TimeInterval = 60 * 60

    /// Всё, из чего собирается URL показа. Совпало с предзагрузкой — инстанс
    /// переиспользуется; нет — страница открыта с другими параметрами и не годится.
    struct Params: Equatable {
        let guid: String
        let email: String?
        let adaptyProfileId: String?
        let revenuecatProfileId: String?

        /// Пустая строка = «не передали» — то же правило, что в `appOriginURL`.
        init(
            guid: String,
            email: String?,
            adaptyProfileId: String?,
            revenuecatProfileId: String?
        ) {
            self.guid = guid
            self.email = Self.nonEmpty(email)
            self.adaptyProfileId = Self.nonEmpty(adaptyProfileId)
            self.revenuecatProfileId = Self.nonEmpty(revenuecatProfileId)
        }

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    /// URL фонового инстанса: app-origin URL + `preload=1`.
    static func preloadURL(paywallURL: URL, params: Params) -> URL {
        let url = WebPaywallLauncher.appOriginURL(
            paywallURL: paywallURL,
            email: params.email,
            guid: params.guid,
            adaptyProfileId: params.adaptyProfileId,
            revenuecatProfileId: params.revenuecatProfileId)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: paramPreload, value: "1"))
        comps?.queryItems = items
        return comps?.url ?? url
    }

    /// Можно ли показать предзагруженный инстанс. Чистая функция (юнит без UIKit).
    static func isReusable(
        loadedWith: Params,
        loadedAt: Date,
        requested: Params,
        now: Date
    ) -> Bool {
        loadedWith == requested && now.timeIntervalSince(loadedAt) < maxAge
    }
}

#if canImport(UIKit) && canImport(WebKit)
/// Сообщения моста от страницы. WKUserContentController держит хендлер сильно,
/// поэтому регистрируется прокси со слабой ссылкой на получателя: пока инстанс
/// лежит в кэше, получателя нет и сообщения отбрасываются (страница не показана).
final class BridgeMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Встроенный WebView пейвола вместе с прокси моста. Один конструктор на показ
/// «с нуля» и на предзагрузку — конфигурация не должна разъехаться.
struct PaywallWebView {
    static let bridgeName = "web2app"

    let webView: WKWebView
    let bridge: BridgeMessageProxy
    let preloaded: Bool

    static func make(url: URL, preloaded: Bool) -> PaywallWebView {
        let bridge = BridgeMessageProxy()
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: bridgeName)
        // Кадр экрана, а не .zero: фоновая страница верстается под ширину 0 и
        // перестраивается уже на глазах у юзера.
        let webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        webView.load(URLRequest(url: url))
        return PaywallWebView(webView: webView, bridge: bridge, preloaded: preloaded)
    }

    /// Снять хендлер моста — иначе контроллер держит прокси, а WebView живёт дольше
    /// показа (классический WKWebView-цикл).
    func tearDown() {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.bridgeName)
        webView.navigationDelegate = nil
        webView.stopLoading()
    }
}

/// Кэш предзагруженных пейволов: `paywallId` → фоновый WKWebView.
/// Только главный поток.
final class PaywallPreloader: NSObject, WKNavigationDelegate {
    static let shared = PaywallPreloader()

    private struct Entry {
        let paywall: PaywallWebView
        let params: PaywallPreload.Params
        let loadedAt: Date
    }

    /// Что интегратор попросил держать наготове — после показа инстанс
    /// пересоздаётся по этому списку.
    private var requested: [String: PaywallPreload.Params] = [:]
    private var entries: [String: Entry] = [:]
    private var memoryObserver: NSObjectProtocol?

    /// Каждой загрузке — свой номер: резолв URL, вернувшийся после повторного
    /// `preload`/`clear`, не должен положить в кэш устаревший инстанс.
    private var generation: [String: Int] = [:]

    private override init() {
        super.init()
        // Мало памяти → отдаём фоновые WebView. Показ сработает обычным путём.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.entries.isEmpty else { return }
            SdkLogger.log("paywall.preload_dropped_memory", level: "warn")
            self.dropAllEntries()
        }
    }

    /// Держать наготове ровно этот набор пейволов с этими параметрами.
    /// Лишние инстансы выгружаются, уже загруженные с теми же параметрами — остаются.
    func preload(
        paywallIds: [String],
        params: PaywallPreload.Params,
        resolve: @escaping (String, @escaping (URL?) -> Void) -> Void
    ) {
        let wanted = Set(paywallIds)
        for id in requested.keys where !wanted.contains(id) {
            requested[id] = nil
            drop(id)
        }
        for id in wanted {
            requested[id] = params
            if let entry = entries[id], entry.params == params { continue }
            load(id, params: params, resolve: resolve)
        }
    }

    /// Готовый инстанс под показ. Забирается из кэша: после показа страница
    /// «грязная» (мог начаться чекаут) и повторно не показывается.
    func take(paywallId: String, params: PaywallPreload.Params) -> PaywallWebView? {
        guard let entry = entries[paywallId] else { return nil }
        entries[paywallId] = nil
        entry.paywall.webView.navigationDelegate = nil
        guard
            PaywallPreload.isReusable(
                loadedWith: entry.params, loadedAt: entry.loadedAt,
                requested: params, now: Date())
        else {
            SdkLogger.log("paywall.preload_miss", context: ["paywallId": paywallId])
            entry.paywall.tearDown()
            return nil
        }
        SdkLogger.log("paywall.preload_hit", context: ["paywallId": paywallId])
        return entry.paywall
    }

    /// После показа: если пейвол в списке предзагрузки — грузим свежий инстанс.
    func refill(
        paywallId: String,
        resolve: @escaping (String, @escaping (URL?) -> Void) -> Void
    ) {
        guard let params = requested[paywallId], entries[paywallId] == nil else { return }
        load(paywallId, params: params, resolve: resolve)
    }

    /// Больше не держать эти пейволы: WebView выгружается, после показа не
    /// пересоздаётся. Остальной набор предзагрузки не трогается.
    func invalidate(paywallIds: [String]) {
        for id in paywallIds {
            requested[id] = nil
            drop(id)
        }
    }

    func clear() {
        requested.removeAll()
        dropAllEntries()
    }

    private func load(
        _ id: String,
        params: PaywallPreload.Params,
        resolve: @escaping (String, @escaping (URL?) -> Void) -> Void
    ) {
        drop(id)
        let gen = (generation[id] ?? 0) + 1
        generation[id] = gen
        resolve(id) { [weak self] paywallURL in
            DispatchQueue.main.async {
                guard let self, self.generation[id] == gen, self.requested[id] == params
                else { return }
                guard let paywallURL else {
                    SdkLogger.error("paywall.preload_resolve_failed", context: ["paywallId": id])
                    return
                }
                let url = PaywallPreload.preloadURL(paywallURL: paywallURL, params: params)
                let paywall = PaywallWebView.make(url: url, preloaded: true)
                paywall.webView.navigationDelegate = self
                self.entries[id] = Entry(paywall: paywall, params: params, loadedAt: Date())
                SdkLogger.log("paywall.preload_started", context: ["paywallId": id])
            }
        }
    }

    private func drop(_ id: String) {
        generation[id] = (generation[id] ?? 0) + 1
        entries.removeValue(forKey: id)?.paywall.tearDown()
    }

    private func dropAllEntries() {
        for id in Array(entries.keys) { drop(id) }
    }

    private func id(of webView: WKWebView) -> String? {
        entries.first { $0.value.paywall.webView === webView }?.key
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = id(of: webView) else { return }
        SdkLogger.log("paywall.preload_ready", context: ["paywallId": id])
    }

    /// Не загрузилась — выкидываем: показ пойдёт обычным путём, а не на страницу ошибки.
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failed(webView, error)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        failed(webView, error)
    }

    /// iOS убила процесс страницы (память) — фоновый инстанс пуст, грузим заново.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = id(of: webView) else { return }
        SdkLogger.log(
            "paywall.preload_process_terminated", context: ["paywallId": id], level: "warn")
        webView.reload()
    }

    private func failed(_ webView: WKWebView, _ error: Error) {
        guard let id = id(of: webView) else { return }
        SdkLogger.error(
            "paywall.preload_failed",
            context: ["paywallId": id, "error": (error as NSError).domain
                + ":" + String((error as NSError).code)])
        drop(id)
    }
}
#endif
