import Foundation

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
#endif

/// Типизированный результат показа веб-пейвола (SDK-трек PM 2026-07-24).
/// Заменяет неоднозначный `EntitlementGrant?` (nil не отличал «не оплатил»
/// от «оплатил, но подтверждение не успело доехать»).
public enum PaywallResult {
    /// Оплата подтверждена — активный грант в руках, открывайте платный флоу.
    case paid(EntitlementGrant)
    /// Пользователь закрыл пейвол, активного гранта нет — оставить бесплатный тариф.
    case notPaid
    /// Окно ожидания истекло без подтверждения (медленный вебхук/сеть).
    /// Доступ может появиться позже — перепроверьте `Web2App.entitlement`.
    case pending
    /// Пейвол не был показан: SDK не сконфигурирован или платформа без UIKit
    /// (ревью 0.4.1 — раньше маскировалось под notPaid).
    case unavailable
}

// Разбор моста (`BridgeEvent`, `BridgeEventParser`, `BridgeMessageRouter`)
// вынесен в FunnelEventBridge.swift — он POC-независим и покрыт юнитами,
// здесь остаётся только UIKit-презентация.

#if canImport(UIKit) && canImport(WebKit)
/// Встроенный показ веб-пейвола в WKWebView с JS-мостом (в отличие от
/// SFSafariViewController, страница может слать SDK события напрямую).
/// На успех оплаты пейвол закрывается АВТОМАТИЧЕСКИ — юзеру не нужно жать
/// «Закрыть»; кнопка остаётся и тоже обрабатывается мостом.
final class WebViewPaywallPresenter: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var retained: WebViewPaywallPresenter?
    private weak var hostController: UIViewController?
    private let paywall: PaywallWebView
    private let onEvent: (BridgeEvent?) -> Void
    private var finished = false
    private weak var spinner: UIActivityIndicatorView?
    private var loadingObservation: NSKeyValueObservation?

    /// Ревью 0.4.1: guard от одновременных показов (см. WebPaywallPresenter).
    private static weak var active: WebViewPaywallPresenter?

    private init(paywall: PaywallWebView, onEvent: @escaping (BridgeEvent?) -> Void) {
        self.paywall = paywall
        self.onEvent = onEvent
    }

    /// Открывает `url` во встроенном WKWebView (модальный full-screen VC с
    /// нативной кнопкой закрытия). `onEvent` вызывается РОВНО один раз:
    /// с событием моста (успех/кнопка) либо nil (юзер закрыл нативно).
    static func present(url: URL, onEvent: @escaping (BridgeEvent?) -> Void) {
        present(paywall: PaywallWebView.make(url: url, preloaded: false), onEvent: onEvent)
    }

    /// Показ готового WebView — в т.ч. предзагруженного (`PaywallPreloader`).
    /// Контракт `onEvent` тот же, что у `present(url:)`.
    static func present(paywall: PaywallWebView, onEvent: @escaping (BridgeEvent?) -> Void) {
        // Ревью 0.4.1: повторный показ завершает предыдущий (его колбэк
        // отработает по обычному пути), не осиротляя completion.
        if let previous = active {
            previous.finish(with: nil)
        }

        let presenter = WebViewPaywallPresenter(paywall: paywall, onEvent: onEvent)
        presenter.retained = presenter // self-owning до finish
        paywall.bridge.target = presenter
        Self.active = presenter

        let webView = paywall.webView
        webView.navigationDelegate = presenter
        if paywall.preloaded {
            // Страница ждала показа, чтобы засчитать просмотр (см. контракт
            // `PaywallPreload.shownScript`); не догрузилась — повтор в didFinish.
            webView.evaluateJavaScript(PaywallPreload.shownScript)
        }

        let vc = UIViewController()
        vc.view = webView
        vc.modalPresentationStyle = .fullScreen

        // Кнопка закрытия. Вместо тёмного круга — размытая подложка (blur /
        // frosted glass): подстраивается под фон пейвола (не давит тёмным
        // пятном на светлом), а крестик поверх остаётся читаемым. tint .label
        // адаптируется к светлой/тёмной теме.
        let blur = UIVisualEffectView(
            effect: UIBlurEffect(style: .systemThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 16
        blur.clipsToBounds = true
        blur.isUserInteractionEnabled = false

        let closeButton = UIButton(type: .system)
        let symbolConfig = UIImage.SymbolConfiguration(
            pointSize: 15, weight: .bold)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: symbolConfig),
            for: .normal)
        closeButton.tintColor = .label
        closeButton.accessibilityLabel = "Close"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(
            presenter, action: #selector(nativeCloseTapped), for: .touchUpInside)

        webView.addSubview(blur)
        webView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            blur.widthAnchor.constraint(equalToConstant: 32),
            blur.heightAnchor.constraint(equalToConstant: 32),
            blur.topAnchor.constraint(
                equalTo: webView.safeAreaLayoutGuide.topAnchor, constant: 8),
            blur.trailingAnchor.constraint(
                equalTo: webView.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            closeButton.topAnchor.constraint(equalTo: blur.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])

        // Пока страница грузится — индикатор вместо белого экрана. Предзагруженная
        // обычно уже готова, и индикатор не появится вовсе.
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        webView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
        ])
        presenter.spinner = spinner
        presenter.loadingObservation = webView.observe(\.isLoading, options: [.initial, .new]) {
            [weak presenter] webView, _ in
            let loading = webView.isLoading
            DispatchQueue.main.async {
                if loading {
                    presenter?.spinner?.startAnimating()
                } else {
                    presenter?.spinner?.stopAnimating()
                }
            }
        }

        presenter.hostController = vc

        guard let top = Self.topViewController() else {
            SdkLogger.error("paywall.no_ui_context")
            presenter.retained = nil
            onEvent(nil)
            return
        }
        SdkLogger.log(
            "paywall.presented_webview",
            context: [
                "preloaded": String(paywall.preloaded),
                "loading": String(webView.isLoading),
            ])
        top.present(vc, animated: true)
    }

    @objc private func nativeCloseTapped() {
        finish(with: nil)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "web2app" else { return }
        // Шрам Б-1: раньше тут стоял `finish(with:)` на ЛЮБОМ распознанном
        // событии — с приходом событий квиза воронка схлопнулась бы на первом
        // экране. Теперь показ закрывает только терминальное событие (их ровно
        // два), а остальные лишь доезжают до слушателя интегратора.
        BridgeMessageRouter.route(message.body) { [weak self] terminal in
            self?.finish(with: terminal)
        }
    }

    private func finish(with event: BridgeEvent?) {
        guard !finished else { return }
        finished = true
        // Ревью 0.4.1: снять script-handler явно — WKUserContentController
        // держит хендлер сильно (классический WKWebView-цикл); сегодня цикла
        // нет, но defense-in-depth дешевле будущей утечки.
        loadingObservation = nil
        paywall.tearDown()
        if Self.active === self { Self.active = nil }
        let controller = hostController
        let callback = onEvent
        controller?.dismiss(animated: true) {
            callback(event)
        }
        if controller == nil {
            callback(event)
        }
        retained = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if paywall.preloaded {
            webView.evaluateJavaScript(PaywallPreload.shownScript)
        }
    }

    /// iOS убила процесс страницы на экране — без перезагрузки юзер видит пустоту.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        SdkLogger.log("paywall.webview_process_terminated", level: "warn")
        webView.reload()
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
