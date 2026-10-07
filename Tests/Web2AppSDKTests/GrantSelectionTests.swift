import XCTest
@testable import Web2AppSDK

/// WEB-2480 п.1 — `entitlement` отдаёт первую ДЕЙСТВУЮЩУЮ запись, а если действующих
/// нет — самую новую (первую в ответе), как раньше. До починки бралась только первая:
/// оплативший со свежей неактивной записью (возврат докупки, истёкшая) видел «не оплачено».
final class GrantSelectionTests: XCTestCase {
    private func body(_ grants: [(String, String)]) -> Data {
        let items = grants.map {
            "{\"level\":\"\($0.0)\",\"status\":\"\($0.1)\",\"expires_at\":null,\"price_id\":\"\($0.0)\"}"
        }
        return "{\"guid\":\"g1\",\"testMode\":false,\"grants\":[\(items.joined(separator: ","))]}"
            .data(using: .utf8)!
    }

    func testActiveOlderGrantWinsOverNewerExpired() {
        let g = EntitlementClient.parseGrant(body([("one_time", "expired"), ("subscription", "active")]))
        XCTAssertEqual(g?.level, "subscription")
        XCTAssertEqual(g?.isActive, true)
    }

    func testActiveOlderGrantWinsOverNewerRevoked() {
        let g = EntitlementClient.parseGrant(
            body([("refunded", "revoked"), ("expired_old", "expired"), ("sub", "active")]))
        XCTAssertEqual(g?.level, "sub")
    }

    func testOnlyInactiveGrantIsReturnedAsIs() {
        let g = EntitlementClient.parseGrant(body([("refunded", "revoked")]))
        XCTAssertEqual(g?.level, "refunded")
        XCTAssertEqual(g?.isActive, false)
    }

    func testNoActiveGrantsReturnsNewest() {
        let g = EntitlementClient.parseGrant(body([("newest", "expired"), ("older", "revoked")]))
        XCTAssertEqual(g?.level, "newest")
    }

    func testFirstOfSeveralActiveGrantsKeepsServerOrder() {
        XCTAssertEqual(
            EntitlementClient.parseGrant(body([("a", "active"), ("b", "active")]))?.level, "a")
    }

    func testEmptyListAndGarbage() {
        XCTAssertNil(EntitlementClient.parseGrant(body([])))
        XCTAssertNil(EntitlementClient.parseGrant("not json".data(using: .utf8)!))
    }
}
