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
final class WebViewPaywallPresenter: NSObject, WKScriptMessageHandler {
    private var retained: WebViewPaywallPresenter?
    private weak var hostController: UIViewController?
    private weak var contentController: WKUserContentController?
    private let onEvent: (BridgeEvent?) -> Void
    private var finished = false

    /// Ревью 0.4.1: guard от одновременных показов (см. WebPaywallPresenter).
    private static weak var active: WebViewPaywallPresenter?

    private init(onEvent: @escaping (BridgeEvent?) -> Void) {
        self.onEvent = onEvent
    }

    /// Открывает `url` во встроенном WKWebView (модальный full-screen VC с
    /// нативной кнопкой закрытия). `onEvent` вызывается РОВНО один раз:
    /// с событием моста (успех/кнопка) либо nil (юзер закрыл нативно).
    static func present(url: URL, onEvent: @escaping (BridgeEvent?) -> Void) {
        // Ревью 0.4.1: повторный показ завершает предыдущий (его колбэк
        // отработает по обычному пути), не осиротляя completion.
        if let previous = active {
            previous.finish(with: nil)
        }

        let presenter = WebViewPaywallPresenter(onEvent: onEvent)
        presenter.retained = presenter // self-owning до finish

        let config = WKWebViewConfiguration()
        config.userContentController.add(presenter, name: "web2app")
        presenter.contentController = config.userContentController
        Self.active = presenter

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))

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

        presenter.hostController = vc

        guard let top = Self.topViewController() else {
            SdkLogger.error("paywall.no_ui_context")
            presenter.retained = nil
            onEvent(nil)
            return
        }
        SdkLogger.log("paywall.presented_webview")
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
        contentController?.removeScriptMessageHandler(forName: "web2app")
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
