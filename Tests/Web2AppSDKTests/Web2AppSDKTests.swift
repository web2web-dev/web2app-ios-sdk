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
}
