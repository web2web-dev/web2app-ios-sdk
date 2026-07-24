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
