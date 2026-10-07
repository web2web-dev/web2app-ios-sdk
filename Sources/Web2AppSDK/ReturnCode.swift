import Foundation

/// WEB-2479 — чем закончился обмен кода из ссылки (`GET /public/handoff/resolve`).
enum CodeExchangeOutcome {
    /// Сервер обменял код на guid — он становится текущим (перезапись хранилища).
    case exchanged(String)
    /// Сервер отверг код (погашен/просрочен — 404), а guid уже сохранён:
    /// отдаём сохранённый успехом (решение владельца 06.10 — повторный переход
    /// по той же ссылке не превращается в ошибку).
    case keptCached(String)
    /// Обмен не удался и подменить нечем: сеть, ответ сервера не 404, нет
    /// сохранённого guid.
    case failed(Web2AppError)
}

/// WEB-2479 — правила обмена кода. Чистые функции (без сети и Keychain) —
/// проверяемы юнит-тестами на любой платформе.
enum ReturnCodeRules {
    /// HTTP-ответ «код не найден / просрочен / уже использован» (контракт
    /// `AttributionResolver.resolveToken`).
    static let codeRejectedStatus = 404

    /// Непустой код, иначе nil (пустая строка = «кода нет», как раньше).
    static func code(from deepLinkValue: String?) -> String? {
        guard let value = deepLinkValue, !value.isEmpty else { return nil }
        return value
    }

    /// Код из возвратной ссылки `<схема-приложения>://handoff?code=<код>`.
    static func code(fromReturnURL url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return code(from: items?.first { $0.name == "code" }?.value)
    }

    /// Итог обмена. Сохранённый guid подставляется ТОЛЬКО при отказе сервера
    /// (404): сбой сети или 5xx/429 — ошибка, иначе покупатель, чья оплата лежит
    /// под новым кодом, молча получил бы старый guid.
    static func outcome(
        _ result: Result<String, Web2AppError>,
        httpStatus: Int,
        cachedGuid: String?
    ) -> CodeExchangeOutcome {
        switch result {
        case .success(let guid):
            return .exchanged(guid)
        case .failure(let error):
            if case .resolveFailed = error,
                httpStatus == codeRejectedStatus,
                let cached = cachedGuid, !cached.isEmpty
            {
                return .keptCached(cached)
            }
            return .failed(error)
        }
    }

    /// Что делает возвратный метод.
    enum ReturnAction {
        /// Окно оплаты библиотеки открыто, кода в адресе нет: закрыть окно,
        /// право по сохранённому guid.
        case dismissWindow
        /// Окно открыто и код есть: закрыть окно и проверить право по сохранённому
        /// guid. Действующая запись есть — код НЕ тратить (остаётся живым для письма
        /// «оплата прошла»); нет — обменять код (решение владельца 07.10:
        /// покупатель бросил окно и оплатил в обычном браузере).
        case dismissWindowThenExchangeIfNoAccess(String)
        /// Окна нет (платили в обычном браузере / пришли из письма): обменять код.
        case exchange(String)
        /// Окна нет и кода в адресе нет: спросить право по сохранённому guid.
        case checkStoredGuid
    }

    /// Решения владельца 06.10 и 07.10: код тратится, когда окна библиотеки нет,
    /// или когда окно открыто, но доступа по сохранённому guid нет.
    static func returnAction(windowOpen: Bool, code: String?) -> ReturnAction {
        switch (windowOpen, code) {
        case (true, let code?): return .dismissWindowThenExchangeIfNoAccess(code)
        case (true, nil): return .dismissWindow
        case (false, let code?): return .exchange(code)
        case (false, nil): return .checkStoredGuid
        }
    }
}

/// WEB-2479 п.2 — ход возвратного метода без UIKit: шаги подставляются снаружи
/// (`Web2App.handleReturnURL` — настоящие, тесты — подмены). Результат в
/// `completion` — ровно один раз.
struct ReturnURLFlow {
    let windowOpen: Bool
    let dismissWindow: () -> Void
    let exchange: (String, @escaping (CodeExchangeOutcome) -> Void) -> Void
    /// Проверка права по сохранённому guid ПЕРЕД решением тратить код (окно
    /// открыто). Всегда настоящая: от неё зависит, сгорит ли код.
    let checkStoredGuid: (@escaping (EntitlementGrant?) -> Void) -> Void
    /// Опрос права по guid, который лежит в хранилище в момент вызова (результат
    /// для колбэка возврата; без колбэка может не ходить в сеть).
    let pollStoredGuid: (@escaping (EntitlementGrant?) -> Void) -> Void

    func run(code: String?, completion: @escaping (EntitlementGrant?) -> Void) {
        switch ReturnCodeRules.returnAction(windowOpen: windowOpen, code: code) {
        case .dismissWindow:
            dismissWindow()
            pollStoredGuid(completion)
        case .dismissWindowThenExchangeIfNoAccess(let code):
            dismissWindow()
            checkStoredGuid { grant in
                if let grant, grant.isActive {
                    completion(grant)
                } else {
                    exchangeThenPoll(code, onFailed: grant, completion: completion)
                }
            }
        case .exchange(let code):
            exchangeThenPoll(code, onFailed: nil, completion: completion)
        case .checkStoredGuid:
            pollStoredGuid(completion)
        }
    }

    private func exchangeThenPoll(
        _ code: String, onFailed: EntitlementGrant?,
        completion: @escaping (EntitlementGrant?) -> Void
    ) {
        exchange(code) { outcome in
            switch outcome {
            case .exchanged, .keptCached:
                pollStoredGuid(completion)
            case .failed:
                completion(onFailed)
            }
        }
    }
}
