import XCTest
@testable import Web2AppSDK

/// Скелет-тесты (WEB-434). Покрывают POC-независимую чистую логику (decode + isActive).
/// Сетевые/Keychain/MMP-пути тестируются интегратором на девайсе (built≠works, L6).
final class Web2AppSDKTests: XCTestCase {
    func testEntitlementDecodeAndActive() throws {
        let json = """
        { "guid": "g1", "grants": [
            { "level": "price_abc", "status": "active", "expires_at": null, "price_id": "price_abc" }
        ] }
        """.data(using: .utf8)!

        struct Resp: Decodable { let guid: String; let grants: [EntitlementGrant] }
        let resp = try JSONDecoder().decode(Resp.self, from: json)

        XCTAssertEqual(resp.grants.count, 1)
        XCTAssertTrue(resp.grants[0].isActive)
        XCTAssertEqual(resp.grants[0].priceId, "price_abc")
    }

    func testExpiredGrantNotActive() throws {
        let json = """
        { "level": "l", "status": "expired", "expires_at": "2020-01-01T00:00:00Z", "price_id": null }
        """.data(using: .utf8)!
        let grant = try JSONDecoder().decode(EntitlementGrant.self, from: json)
        XCTAssertFalse(grant.isActive)
    }

    // MARK: WEB-525 под-атом B — openWebPaywall (app-origin URL + guid-поллинг возврат)

    /// app-origin URL несёт origin=app + email + guid (prefill + guid-поллинг).
    func testAppOriginURLIncludesOriginEmailGuid() {
        let base = URL(string: "https://client.example.com/paywall/pw1")!
        let url = WebPaywallLauncher.appOriginURL(
            paywallURL: base, email: "user@app.example", guid: "g-123"
        )
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(
            (comps.queryItems ?? []).map { ($0.name, $0.value) },
            uniquingKeysWith: { a, _ in a }
        )
        XCTAssertEqual(items["origin"], "app")
        XCTAssertEqual(items["email"], "user@app.example")
        XCTAssertEqual(items["guid"], "g-123")
        XCTAssertEqual(comps.path, "/paywall/pw1")
    }

    /// email опускается когда nil; существующий query пейвола сохраняется; guid всегда есть.
    func testAppOriginURLOmitsEmailWhenNilAndPreservesQuery() {
        let base = URL(string: "https://client.example.com/paywall/pw1?utm=x")!
        let url = WebPaywallLauncher.appOriginURL(paywallURL: base, email: nil, guid: "g-9")
        let items = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? [])
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { a, _ in a }
        )
        XCTAssertNil(items["email"])
        XCTAssertEqual(items["origin"], "app")
        XCTAssertEqual(items["guid"], "g-9")
        XCTAssertEqual(items["utm"], "x") // не затёрли
    }

    /// поллинг останавливается и отдаёт грант, как только он active (Adapty-стиль).
    func testPollStopsOnActiveGrant() {
        let exp = expectation(description: "poll-active")
        var attempts = 0
        let active = EntitlementGrant(
            level: "price_x", status: "active", expiresAt: nil, priceId: "price_x"
        )
        WebPaywallLauncher.pollForActiveGrant(
            interval: 0.01,
            maxAttempts: 5,
            fetch: { cb in
                attempts += 1
                cb(attempts >= 2 ? active : nil) // nil, потом active на 2-й попытке
            },
            completion: { grant in
                XCTAssertNotNil(grant)
                XCTAssertTrue(grant?.isActive == true)
                XCTAssertEqual(attempts, 2)
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 2)
    }

    /// поллинг сдаётся (nil) после maxAttempts без active-гранта.
    func testPollGivesUpAfterMaxAttempts() {
        let exp = expectation(description: "poll-giveup")
        var attempts = 0
        WebPaywallLauncher.pollForActiveGrant(
            interval: 0.01,
            maxAttempts: 3,
            fetch: { cb in
                attempts += 1
                cb(nil)
            },
            completion: { grant in
                XCTAssertNil(grant)
                XCTAssertEqual(attempts, 3)
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 2)
    }
}

// MARK: - Возвратный deep-link «Закрыть» (WEB-800 контракт <scheme>://handoff?code=...)

extension Web2AppSDKTests {
    /// Возвратная ссылка success-экрана распознаётся по host == "handoff".
    func testIsHandoffReturnURLRecognizesContractLink() {
        XCTAssertTrue(
            WebPaywallLauncher.isHandoffReturnURL(URL(string: "myapp://handoff?code=ABCD1234")!)
        )
        XCTAssertTrue(
            WebPaywallLauncher.isHandoffReturnURL(URL(string: "MyApp://HANDOFF")!)
        )
    }

    /// Чужие deep-link'и приложения НЕ распознаются как наш возврат.
    func testIsHandoffReturnURLRejectsForeignLinks() {
        XCTAssertFalse(
            WebPaywallLauncher.isHandoffReturnURL(URL(string: "myapp://settings")!)
        )
        XCTAssertFalse(
            WebPaywallLauncher.isHandoffReturnURL(URL(string: "https://example.com/handoff")!)
        )
    }

    /// Публичный обработчик: не-наш URL → false (интегратор передаёт все URL подряд).
    func testHandleReturnURLPassesThroughForeignLinks() {
        XCTAssertFalse(Web2App.handleReturnURL(URL(string: "myapp://other")!))
        XCTAssertTrue(Web2App.handleReturnURL(URL(string: "myapp://handoff?code=X")!))
    }
}

// MARK: - Открытие по paywallId (резолв публичного URL, SDK-трек PM 2026-07-24)

extension Web2AppSDKTests {
    /// Ответ ручки /public/paywall-url/:id парсится в URL.
    func testParsePaywallUrlResponseHappyPath() {
        let json = #"{"success":true,"data":{"url":"https://test.sharamuga.click"}}"#
        let url = WebPaywallLauncher.parsePaywallUrlResponse(Data(json.utf8))
        XCTAssertEqual(url?.absoluteString, "https://test.sharamuga.click")
    }

    /// Мусор/404-тело → nil (SDK отдаст completion(nil), приложение покажет свой фолбэк).
    func testParsePaywallUrlResponseGarbage() {
        XCTAssertNil(WebPaywallLauncher.parsePaywallUrlResponse(Data("{}".utf8)))
        XCTAssertNil(WebPaywallLauncher.parsePaywallUrlResponse(Data("not json".utf8)))
        let noUrl = #"{"success":true,"data":{}}"#
        XCTAssertNil(WebPaywallLauncher.parsePaywallUrlResponse(Data(noUrl.utf8)))
    }
}

// MARK: - Разбор ответа /public/handoff/resolve (guid в обёртке API)

extension Web2AppSDKTests {
    /// Реальный прод-ответ: guid лежит внутри `data` обёртки `{success, data}`.
    func testParseGuidResponseWrappedBody() {
        let json = #"{"success":true,"data":{"guid":"live-sdk-check-3","projectId":"b6bb21dd"}}"#
        XCTAssertEqual(
            AttributionResolver.parseGuidResponse(Data(json.utf8)), "live-sdk-check-3"
        )
    }

    /// Плоское тело `{guid}` продолжает работать (старые/иные окружения).
    func testParseGuidResponseFlatBody() {
        let json = #"{"guid":"g-flat"}"#
        XCTAssertEqual(AttributionResolver.parseGuidResponse(Data(json.utf8)), "g-flat")
    }

    /// Тело ошибки 404 (код не найден / просрочен / использован) → nil → .resolveFailed.
    func testParseGuidResponseErrorBody() {
        let json = #"{"message":"Handoff code not found","error":"Not Found","statusCode":404}"#
        XCTAssertNil(AttributionResolver.parseGuidResponse(Data(json.utf8)))
    }

    /// Мусор, пустое тело и обёртка без guid → nil.
    func testParseGuidResponseGarbage() {
        XCTAssertNil(AttributionResolver.parseGuidResponse(Data("not json".utf8)))
        XCTAssertNil(AttributionResolver.parseGuidResponse(Data()))
        XCTAssertNil(AttributionResolver.parseGuidResponse(Data("{}".utf8)))
        XCTAssertNil(AttributionResolver.parseGuidResponse(Data(#"{"success":true,"data":{}}"#.utf8)))
    }

    /// Пустой guid — не успех (и в обёртке, и в плоском теле).
    func testParseGuidResponseEmptyGuid() {
        XCTAssertNil(
            AttributionResolver.parseGuidResponse(Data(#"{"success":true,"data":{"guid":""}}"#.utf8))
        )
        XCTAssertNil(AttributionResolver.parseGuidResponse(Data(#"{"guid":""}"#.utf8)))
    }
}

// MARK: - JS-мост WebView-режима (0.4.0)

extension Web2AppSDKTests {
    /// Событие успеха оплаты с моста распознаётся.
    func testBridgeParsesPaymentSuccess() {
        let body: [String: Any] = ["source": "web2app", "event": "paywall_result", "status": "success"]
        XCTAssertEqual(BridgeEventParser.parse(body), .paymentSuccess)
    }

    /// Кнопка «Закрыть» с моста распознаётся.
    func testBridgeParsesClose() {
        XCTAssertEqual(BridgeEventParser.parse(["event": "close"]), .close)
    }

    /// Мусор/чужие события → nil (SDK игнорирует).
    func testBridgeRejectsGarbage() {
        XCTAssertNil(BridgeEventParser.parse("строка"))
        XCTAssertNil(BridgeEventParser.parse(["event": "unknown"]))
        XCTAssertNil(BridgeEventParser.parse(["event": "paywall_result", "status": "fail"]))
    }
}

// MARK: - Б-1: события воронки из моста (разбор)

extension Web2AppSDKTests {
    /// Каждое из пяти событий квиза разбирается по имени (а не выбрасывается).
    func testFunnelParsesAllFiveQuizEvents() {
        for name in [
            "quiz_start", "quiz_screen_view", "quiz_answer",
            "quiz_email_submit", "quiz_complete",
        ] {
            let message = BridgeEventParser.parseMessage(["event": name])
            XCTAssertEqual(message?.name, name, "событие \(name) должно разбираться")
        }
    }

    /// Безопасные поля события экрана доезжают полностью (включая metadata.*).
    func testFunnelParsesScreenAndMetadataFields() {
        let body: [String: Any] = [
            "source": "web2app",
            "event": "quiz_answer",
            "screenId": "scr-2",
            "screenIndex": 1,
            "screenTotal": 7,
            "metadata": ["blockId": "blk-9", "blockType": "single_choice"],
        ]
        let data = BridgeEventParser.parseMessage(body)?.data
        XCTAssertEqual(data?.screenId, "scr-2")
        XCTAssertEqual(data?.screenIndex, 1)
        XCTAssertEqual(data?.screenTotal, 7)
        XCTAssertEqual(data?.blockId, "blk-9")
        XCTAssertEqual(data?.blockType, "single_choice")
    }

    /// `paywall_result:dismissed` — распознан как событие (доедет до слушателя).
    func testFunnelParsesPaywallDismissed() {
        let message = BridgeEventParser.parseMessage([
            "event": "paywall_result", "status": "dismissed",
        ])
        XCTAssertEqual(message?.name, "paywall_result")
        XCTAssertEqual(message?.status, "dismissed")
    }

    /// Незнакомое событие — не ошибка: разбирается и просто едет дальше.
    func testFunnelParsesUnknownEventName() {
        XCTAssertEqual(BridgeEventParser.parseMessage(["event": "brand_new"])?.name, "brand_new")
    }

    /// Отсутствующие поля → nil, без падений и без выдуманных значений.
    func testFunnelMissingFieldsAreNil() {
        let data = BridgeEventParser.parseMessage(["event": "quiz_start"])?.data
        XCTAssertEqual(data, FunnelEventData())
        XCTAssertNil(data?.screenId)
        XCTAssertNil(data?.screenIndex)
        XCTAssertNil(data?.screenTotal)
        XCTAssertNil(data?.blockId)
        XCTAssertNil(data?.blockType)
    }

    /// Поля не того типа игнорируются: число вместо строки, строка вместо числа,
    /// metadata не объектом. Событие при этом остаётся валидным.
    func testFunnelBrokenFieldTypesAreSkipped() {
        let body: [String: Any] = [
            "event": "quiz_screen_view",
            "screenId": 42, // число вместо строки
            "screenIndex": "3", // строка вместо числа
            "screenTotal": 1.5, // дробь — не индекс экрана
            "metadata": "not-an-object",
        ]
        let message = BridgeEventParser.parseMessage(body)
        XCTAssertEqual(message?.name, "quiz_screen_view")
        XCTAssertNil(message?.data.screenId)
        XCTAssertNil(message?.data.screenIndex)
        XCTAssertNil(message?.data.screenTotal)
        XCTAssertNil(message?.data.blockId)
    }

    /// metadata есть, но нужных ключей нет → blockId/blockType nil, не падаем.
    func testFunnelMetadataWithoutExpectedKeys() {
        let body: [String: Any] = [
            "event": "quiz_answer", "metadata": ["other": "x"],
        ]
        let message = BridgeEventParser.parseMessage(body)
        XCTAssertNotNil(message)
        XCTAssertNil(message?.data.blockId)
        XCTAssertNil(message?.data.blockType)
    }

    /// Не словарь / нет ключа `event` / event не строка → сообщения нет вовсе.
    func testFunnelRejectsNonMessages() {
        XCTAssertNil(BridgeEventParser.parseMessage("строка"))
        XCTAssertNil(BridgeEventParser.parseMessage(42))
        XCTAssertNil(BridgeEventParser.parseMessage(["source": "web2app"]))
        XCTAssertNil(BridgeEventParser.parseMessage(["event": 1]))
    }
}

// MARK: - Б-1: терминальность (шрам — событие квиза НЕ закрывает WebView)

extension Web2AppSDKTests {
    /// Терминальны РОВНО два события: paywall_result:success и close.
    func testTerminalEventsAreExactlyTwo() {
        let terminal: [(String, String?)] = [
            ("paywall_result", "success"),
            ("close", nil),
        ]
        let nonTerminal: [(String, String?)] = [
            ("quiz_start", nil),
            ("quiz_screen_view", nil),
            ("quiz_answer", nil),
            ("quiz_email_submit", nil),
            ("quiz_complete", nil),
            ("paywall_result", "dismissed"),
            ("paywall_result", nil),
            ("brand_new", nil),
        ]
        for (name, status) in terminal {
            let message = BridgeMessage(name: name, status: status)
            XCTAssertNotNil(
                BridgeEventParser.terminalEvent(message), "\(name)/\(status ?? "-") терминально")
        }
        for (name, status) in nonTerminal {
            let message = BridgeMessage(name: name, status: status)
            XCTAssertNil(
                BridgeEventParser.terminalEvent(message),
                "\(name)/\(status ?? "-") НЕ должно закрывать показ")
        }
    }

    /// Роутер: событие квиза уходит слушателю и НЕ закрывает показ.
    func testRouterQuizEventDoesNotClosePresentation() {
        var emitted: [String] = []
        var terminals: [BridgeEvent] = []
        BridgeMessageRouter.route(
            ["event": "quiz_screen_view", "screenIndex": 0],
            emit: { name, _ in emitted.append(name) },
            onTerminal: { terminals.append($0) })
        XCTAssertEqual(emitted, ["quiz_screen_view"])
        XCTAssertTrue(terminals.isEmpty, "квиз-событие закрыло бы воронку на первом экране")
    }

    /// Роутер: `dismissed` доезжает до слушателя, но окно живёт (следом придёт close).
    func testRouterDismissedIsNotTerminal() {
        var emitted: [String] = []
        var terminals: [BridgeEvent] = []
        BridgeMessageRouter.route(
            ["event": "paywall_result", "status": "dismissed"],
            emit: { name, _ in emitted.append(name) },
            onTerminal: { terminals.append($0) })
        XCTAssertEqual(emitted, ["paywall_result"])
        XCTAssertTrue(terminals.isEmpty)
    }

    /// Роутер: терминальное событие сперва отдаётся слушателю, потом закрывает показ.
    func testRouterEmitsBeforeClosing() {
        var order: [String] = []
        BridgeMessageRouter.route(
            ["event": "close"],
            emit: { name, _ in order.append("emit:\(name)") },
            onTerminal: { order.append("terminal:\($0)") })
        XCTAssertEqual(order, ["emit:close", "terminal:close"])
    }

    /// Роутер: успех оплаты закрывает показ (регрессия пейвола не поехала).
    func testRouterPaymentSuccessStillCloses() {
        var terminals: [BridgeEvent] = []
        BridgeMessageRouter.route(
            ["event": "paywall_result", "status": "success"],
            emit: { _, _ in },
            onTerminal: { terminals.append($0) })
        XCTAssertEqual(terminals, [.paymentSuccess])
    }

    /// Роутер: мусор не порождает ни события слушателю, ни закрытия.
    func testRouterIgnoresGarbage() {
        var touched = false
        BridgeMessageRouter.route(
            "строка", emit: { _, _ in touched = true }, onTerminal: { _ in touched = true })
        XCTAssertFalse(touched)
    }
}

// MARK: - Б-1: публичный слушатель интегратора

extension Web2AppSDKTests {
    /// Слушатель получает имя события и поля; отписка (nil) выключает доставку.
    func testFunnelEventListenerReceivesAndUnsubscribes() {
        var received: [(String, FunnelEventData)] = []
        Web2App.setFunnelEventListener { name, data in received.append((name, data)) }
        defer { Web2App.setFunnelEventListener(nil) }

        // Тест исполняется на главном потоке — доставка синхронная (правило SDK).
        Web2App.emitFunnelEvent("quiz_answer", FunnelEventData(screenId: "s1", screenIndex: 2))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "quiz_answer")
        XCTAssertEqual(received.first?.1.screenId, "s1")
        XCTAssertEqual(received.first?.1.screenIndex, 2)

        Web2App.setFunnelEventListener(nil)
        Web2App.emitFunnelEvent("quiz_complete", FunnelEventData())
        XCTAssertEqual(received.count, 1, "после отписки события приходить не должны")
    }

    /// Колбэк интегратора приходит на ГЛАВНЫЙ поток, даже если мост дернул с фонового.
    func testFunnelEventListenerDeliversOnMainThread() {
        let exp = expectation(description: "main-thread")
        Web2App.setFunnelEventListener { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            exp.fulfill()
        }
        defer { Web2App.setFunnelEventListener(nil) }
        DispatchQueue.global().async {
            Web2App.emitFunnelEvent("quiz_start", FunnelEventData())
        }
        wait(for: [exp], timeout: 2)
    }
}

// MARK: - Б-3: profile-id подписочных платформ в URL страницы

extension Web2AppSDKTests {
    /// Имена параметров — контракт с фронтом (providerProfileLink.ts), не «похожие».
    func testAppOriginURLCarriesProviderProfileIds() {
        let base = URL(string: "https://client.example.com/paywall/pw1")!
        let url = WebPaywallLauncher.appOriginURL(
            paywallURL: base,
            email: nil,
            guid: "g-1",
            adaptyProfileId: "adapty-123",
            revenuecatProfileId: "rc-456")
        let items = Self.queryItems(of: url)
        XCTAssertEqual(items["adapty_profile_id"], "adapty-123")
        XCTAssertEqual(items["revenuecat_profile_id"], "rc-456")
        XCTAssertEqual(items["guid"], "g-1")
        XCTAssertEqual(items["origin"], "app")
    }

    /// Не передали / пустая строка → параметра нет вовсе (`adapty_profile_id=` слать нельзя).
    func testAppOriginURLOmitsEmptyProfileIds() {
        let base = URL(string: "https://client.example.com/p")!
        let noneURL = WebPaywallLauncher.appOriginURL(paywallURL: base, email: nil, guid: "g")
        XCTAssertNil(Self.queryItems(of: noneURL)["adapty_profile_id"])
        XCTAssertNil(Self.queryItems(of: noneURL)["revenuecat_profile_id"])

        let emptyURL = WebPaywallLauncher.appOriginURL(
            paywallURL: base, email: nil, guid: "g",
            adaptyProfileId: "", revenuecatProfileId: "")
        XCTAssertNil(Self.queryItems(of: emptyURL)["adapty_profile_id"])
        XCTAssertNil(Self.queryItems(of: emptyURL)["revenuecat_profile_id"])
    }

    /// Только один провайдер — второй параметр не появляется.
    func testAppOriginURLCarriesSingleProvider() {
        let base = URL(string: "https://client.example.com/p")!
        let url = WebPaywallLauncher.appOriginURL(
            paywallURL: base, email: nil, guid: "g", revenuecatProfileId: "rc-1")
        let items = Self.queryItems(of: url)
        XCTAssertEqual(items["revenuecat_profile_id"], "rc-1")
        XCTAssertNil(items["adapty_profile_id"])
    }

    /// Исходный query страницы сохраняется, значения экранируются (не конкатенация).
    func testAppOriginURLPreservesQueryAndEncodesProfileIds() {
        let base = URL(string: "https://client.example.com/p?utm=x&a=b")!
        let url = WebPaywallLauncher.appOriginURL(
            paywallURL: base,
            email: "user+tag@app.example",
            guid: "g-1",
            adaptyProfileId: "id with space&amp")
        let items = Self.queryItems(of: url)
        XCTAssertEqual(items["utm"], "x")
        XCTAssertEqual(items["a"], "b")
        XCTAssertEqual(items["email"], "user+tag@app.example")
        XCTAssertEqual(items["adapty_profile_id"], "id with space&amp")
        // Сырое `&` внутри значения обязано быть экранировано, иначе оно
        // распалось бы на лишний параметр.
        XCTAssertFalse(url.absoluteString.contains("id with space&amp"))
    }

    /// Хелпер: query-параметры URL словарём (первое вхождение выигрывает).
    static func queryItems(of url: URL) -> [String: String?] {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(
            (comps?.queryItems ?? []).map { ($0.name, $0.value) },
            uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Б-2: встроенный показ квиза

extension Web2AppSDKTests {
    /// Событие закрытия → причина: страница / оплата / нативный крестик.
    func testQuizResultMapsCloseReasons() {
        XCTAssertEqual(QuizPresentation.result(for: .close), .closed(.page))
        XCTAssertEqual(QuizPresentation.result(for: .paymentSuccess), .closed(.paid))
        XCTAssertEqual(QuizPresentation.result(for: nil), .closed(.user))
    }

    /// URL квиза собирается ТЕМ ЖЕ билдером: origin/guid/email/profile-id + исходный query.
    func testQuizURLUsesAppOriginBuilder() {
        let base = URL(string: "https://client.example.com/q/quiz-1?utm=y")!
        let url = QuizPresentation.quizURL(
            quizURL: base,
            email: "u@app.example",
            guid: "g-quiz",
            adaptyProfileId: "adapty-1",
            revenuecatProfileId: nil)
        let items = Self.queryItems(of: url)
        XCTAssertEqual(items["origin"], "app")
        XCTAssertEqual(items["guid"], "g-quiz")
        XCTAssertEqual(items["email"], "u@app.example")
        XCTAssertEqual(items["adapty_profile_id"], "adapty-1")
        XCTAssertNil(items["revenuecat_profile_id"])
        XCTAssertEqual(items["utm"], "y")
        XCTAssertEqual(url.path, "/q/quiz-1")
    }

    /// `quiz_complete` не терминален — экран квиза на нём НЕ закрывается
    /// (страница после квиза часто сама ведёт на пейвол в том же WebView).
    func testQuizCompleteDoesNotCloseQuiz() {
        var terminals: [BridgeEvent] = []
        BridgeMessageRouter.route(
            ["event": "quiz_complete", "screenIndex": 6, "screenTotal": 7],
            emit: { _, _ in },
            onTerminal: { terminals.append($0) })
        XCTAssertTrue(terminals.isEmpty)
    }

    /// Без `configure` квиз не показывается: unavailable (это НЕ «закрыли»).
    func testOpenQuizEmbeddedWithoutConfigureIsUnavailable() {
        var result: QuizResult?
        Web2App.openQuizEmbedded(quizURL: URL(string: "https://client.example.com/q/1")!) {
            result = $0
        }
        XCTAssertEqual(result, .unavailable)
    }

    // MARK: - WEB-1384: окно попыток отпечатка (2 часа с первой неудачи)

    /// Нет метки первой неудачи → пробовать можно.
    func testFingerprintWindowAllowsWhenNoFailureRecorded() {
        XCTAssertTrue(
            FingerprintResolver.isWithinAttemptWindow(firstFailedAt: nil, now: Date()))
    }

    /// Внутри окна (10 минут после первой неудачи) → пробовать можно.
    func testFingerprintWindowAllowsInsideTwoHours() {
        let first = Date()
        let now = first.addingTimeInterval(10 * 60)
        XCTAssertTrue(
            FingerprintResolver.isWithinAttemptWindow(firstFailedAt: first, now: now))
    }

    /// Окно истекло (2 часа + секунда) → в сеть не ходим.
    func testFingerprintWindowBlocksAfterTwoHours() {
        let first = Date()
        let now = first.addingTimeInterval(2 * 60 * 60 + 1)
        XCTAssertFalse(
            FingerprintResolver.isWithinAttemptWindow(firstFailedAt: first, now: now))
    }
}
