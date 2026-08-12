import Foundation

/// Б-1 — JS-мост `web2app` со страницы веб-воронки (embedded-режим).
///
/// Контракт общий с Android/фронтом (`frontend/src/utils/web2appBridge.ts`),
/// но ФОРМА доставки на iOS другая: страница шлёт
/// `window.webkit.messageHandlers.web2app.postMessage({...})`, и в
/// `WKScriptMessageHandler` тело приезжает уже разобранным ОБЪЕКТОМ
/// (`[String: Any]`), а не JSON-строкой как в Android-ветке. Поэтому парсер
/// работает со словарём — своего JSON-разбора тут нет и быть не должно.
///
/// Сегодня приходят: `quiz_start`, `quiz_screen_view`, `quiz_answer`,
/// `quiz_email_submit`, `quiz_complete` (события прохождения квиза),
/// `paywall_result` со `status` (`success` / `dismissed`) и `close`.
///
/// ⚠ Закрывают показ РОВНО два события — см. `BridgeEventParser.terminalEvent`.
/// Всё остальное доезжает до слушателя интегратора и оставляет WebView открытым.

/// Безопасные поля события воронки. PII в мост НЕ уходит: email и сырые значения
/// ответов веб вырезает на своей стороне — сюда доезжают только идентификаторы.
///
/// Любое поле может отсутствовать (или прийти не того типа) — тогда оно `nil`.
public struct FunnelEventData: Equatable {
    /// Идентификатор экрана воронки.
    public let screenId: String?
    /// Порядковый номер экрана (с нуля).
    public let screenIndex: Int?
    /// Сколько экранов в воронке всего.
    public let screenTotal: Int?
    /// `metadata.blockId` — идентификатор блока, породившего событие.
    public let blockId: String?
    /// `metadata.blockType` — тип блока (например `single_choice`).
    public let blockType: String?

    public init(
        screenId: String? = nil,
        screenIndex: Int? = nil,
        screenTotal: Int? = nil,
        blockId: String? = nil,
        blockType: String? = nil
    ) {
        self.screenId = screenId
        self.screenIndex = screenIndex
        self.screenTotal = screenTotal
        self.blockId = blockId
        self.blockType = blockType
    }
}

/// События JS-моста, ЗАКРЫВАЮЩИЕ показ (см. `BridgeEventParser.terminalEvent`):
///  - `{event: "paywall_result", status: "success"}` — оплата подтверждена
///    (авто, без действий юзера);
///  - `{event: "close"}` — тап по кнопке «Закрыть» на странице.
enum BridgeEvent: Equatable {
    case paymentSuccess
    case close
}

/// Разобранное сообщение моста: имя события + безопасные поля + `status`
/// (нужен только для `paywall_result`, наружу не публикуется).
struct BridgeMessage: Equatable {
    let name: String
    let status: String?
    let data: FunnelEventData

    init(name: String, status: String? = nil, data: FunnelEventData = FunnelEventData()) {
        self.name = name
        self.status = status
        self.data = data
    }
}

enum BridgeEventParser {
    /// Событие результата пейвола (успех/закрытие пользователем).
    private static let eventPaywallResult = "paywall_result"

    /// Кнопка «Закрыть» на странице.
    private static let eventClose = "close"

    /// Статус `paywall_result`, означающий подтверждённую оплату.
    private static let statusSuccess = "success"

    /// Разбирает ЛЮБОЕ событие моста: незнакомое имя — не ошибка, оно просто
    /// доедет до слушателя и никого не закроет. Не словарь / нет ключа `event`
    /// (или он не строка) → nil. Поле не того типа или отсутствует → поле
    /// пропускается: force-unwrap'ов нет, упасть тут нечему.
    static func parseMessage(_ body: Any) -> BridgeMessage? {
        guard let dict = body as? [String: Any],
            let name = dict["event"] as? String
        else { return nil }
        let metadata = dict["metadata"] as? [String: Any]
        return BridgeMessage(
            name: name,
            status: dict["status"] as? String,
            data: FunnelEventData(
                screenId: dict["screenId"] as? String,
                screenIndex: intField(dict["screenIndex"]),
                screenTotal: intField(dict["screenTotal"]),
                blockId: metadata?["blockId"] as? String,
                blockType: metadata?["blockType"] as? String
            )
        )
    }

    /// ТЕРМИНАЛЬНОСТЬ (шрам Б-1): какие события закрывают показ. Их РОВНО два —
    /// `paywall_result:success` и `close`. Всё остальное (включая все `quiz_*` и
    /// `paywall_result:dismissed`) возвращает nil = окно остаётся открытым.
    ///
    /// Функция чистая и живёт здесь, а не внутри презентера, именно чтобы юнит
    /// ловил регрессию «событие квиза закрыло воронку на первом же экране».
    static func terminalEvent(_ message: BridgeMessage) -> BridgeEvent? {
        if message.name == eventPaywallResult && message.status == statusSuccess {
            return .paymentSuccess
        }
        if message.name == eventClose { return .close }
        return nil
    }

    /// Совместимость: старый контракт «тело → терминальное событие или nil».
    /// Поведение не изменилось — знали два события, знаем те же два.
    static func parse(_ body: Any) -> BridgeEvent? {
        parseMessage(body).flatMap(terminalEvent)
    }

    /// Целочисленное поле. JS-числа приезжают через мост как `NSNumber`, но
    /// строка вместо числа (`"1"`), дробь и `Bool` — это НЕ индекс экрана,
    /// такие значения пропускаем (паритет Android-regex `-?\d+`).
    private static func intField(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is Bool { return nil }
        if let int = value as? Int { return int }
        if let double = value as? Double, double == double.rounded(),
            double.magnitude < 1e15
        {
            return Int(double)
        }
        return nil
    }
}

/// Маршрутизация сообщения моста — одна на весь SDK, чтобы правило «что закрывает
/// показ» проверялось юнитом, а не только жило внутри презентера.
///
/// Порядок: сперва событие уходит слушателю интегратора, потом (и только если оно
/// терминальное) вызывается `onTerminal` — закрытие показа.
enum BridgeMessageRouter {
    /// `emit` инъектируется только ради тестов (по умолчанию — реальный
    /// слушатель интегратора), `onTerminal` подставляет презентер.
    static func route(
        _ body: Any,
        emit: (String, FunnelEventData) -> Void = Web2App.emitFunnelEvent,
        onTerminal: (BridgeEvent) -> Void
    ) {
        guard let message = parseMessage(body) else { return }
        emit(message.name, message.data)
        if let terminal = BridgeEventParser.terminalEvent(message) {
            onTerminal(terminal)
        }
    }

    private static func parseMessage(_ body: Any) -> BridgeMessage? {
        BridgeEventParser.parseMessage(body)
    }
}
