import Foundation

/// Атом Б-2 — чем закончился встроенный показ КВИЗА (`Web2App.openQuizEmbedded`).
///
/// У квиза нет результата-оплаты, поэтому это НЕ `PaywallResult`: наблюдаемое —
/// поток событий прохождения (он идёт в `Web2App.setFunnelEventListener`) плюс
/// факт закрытия экрана. Право SDK в квиз-режиме не поллит — за грантом идите в
/// `Web2App.entitlement` (или показывайте пейвол своим методом).
public enum QuizResult: Equatable {
    /// Экран квиза закрылся. Почему — см. `QuizCloseReason`.
    case closed(QuizCloseReason)

    /// Квиз НЕ был показан: SDK не сконфигурирован (`Web2App.configure`) или
    /// платформа без UIKit/WebKit. Отличается от `closed` — там экран показали.
    /// Паритет `PaywallResult.unavailable`.
    case unavailable
}

/// Почему закрылся экран квиза.
public enum QuizCloseReason: Equatable {
    /// Страница попросила закрыть экран — событие `close` (её кнопка «Закрыть»).
    case page

    /// Юзер закрыл экран сам: нативный крестик поверх WebView.
    case user

    /// Внутри ТОГО ЖЕ WebView прошла оплата (`paywall_result:success`) — квиз довёл
    /// до пейвола, и показ закрылся на успехе. Грант подтверждайте
    /// `Web2App.entitlement`: подтверждение оплаты доезжает вебхуком и может
    /// отставать на несколько секунд.
    case paid
}

/// Атом Б-2 — квиз-режим встроенного показа. Механика показа ПЕРЕИСПОЛЬЗУЕТСЯ целиком
/// (`WebViewPaywallPresenter` + мост): второго WebView-класса в SDK нет.
///
/// Отличие квиза от пейвола живёт ровно здесь — в том, ЧТО делает колбэк показа.
/// У пейвола это поллинг гранта → `PaywallResult`; у квиза оплаты нет, поэтому
/// событие закрытия сразу отображается в `QuizResult`, без сетевых запросов.
enum QuizPresentation {
    /// URL квиза собирается ТЕМ ЖЕ app-origin билдером, что и URL пейвола
    /// (`WebPaywallLauncher.appOriginURL`): `origin=app` + guid (+ email и profile-id
    /// Adapty/RevenueCat, если есть), исходный query сохраняется, значения кодируются.
    ///
    /// guid тут не косметика: по нему веб связывает прохождение квиза с тем же
    /// пользователем, что и последующую оплату. Отдельного билдера у квиза нет
    /// намеренно — руками склеенный query потерял бы и то, и другое.
    static func quizURL(
        quizURL: URL,
        email: String?,
        guid: String,
        adaptyProfileId: String?,
        revenuecatProfileId: String?
    ) -> URL {
        WebPaywallLauncher.appOriginURL(
            paywallURL: quizURL,
            email: email,
            guid: guid,
            adaptyProfileId: adaptyProfileId,
            revenuecatProfileId: revenuecatProfileId)
    }

    /// Событие, закрывшее показ, → результат квиза. Чистая функция (юнит без UIKit).
    ///
    /// `nil` = закрыли нативно (крестик поверх WebView). `quiz_complete` сюда не
    /// приходит вовсе — он не терминален, показ на нём НЕ закрывается (страница после
    /// квиза часто сама ведёт на пейвол в том же WebView).
    static func result(for event: BridgeEvent?) -> QuizResult {
        switch event {
        case .close: return .closed(.page)
        case .paymentSuccess: return .closed(.paid)
        case nil: return .closed(.user)
        }
    }
}
