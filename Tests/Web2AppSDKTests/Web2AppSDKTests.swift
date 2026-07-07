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
