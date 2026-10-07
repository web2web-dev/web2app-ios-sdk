import XCTest
@testable import Web2AppSDK

/// WEB-2480 п.2 — `entitlements` различает «записей нет» и «не удалось спросить».
/// Старый `entitlement` отвечал `nil` на всё сразу: приложение по примеру README
/// отнимало доступ у оплатившего без сети.
final class EntitlementsResultTests: XCTestCase {
    private let okBody = """
    {"guid":"g1","testMode":true,"grants":[
      {"level":"old","status":"expired","expires_at":null,"price_id":"old"},
      {"level":"sub","status":"active","expires_at":null,"price_id":"sub"}
    ]}
    """.data(using: .utf8)!

    func testSuccessCarriesAllGrantsTestModeAndActiveGrant() throws {
        let snap = try EntitlementClient.classify(data: okBody, httpStatus: 200, networkError: nil).get()
        XCTAssertEqual(snap.guid, "g1")
        XCTAssertEqual(snap.grants.map(\.level), ["old", "sub"])
        XCTAssertTrue(snap.testMode)
        XCTAssertEqual(snap.activeGrant?.level, "sub")
    }

    /// Четыре случая — четыре разных результата.
    func testNetworkHttpGarbageAndEmptyAreDistinct() throws {
        struct Offline: Error {}
        guard case .failure(.network) = EntitlementClient.classify(
            data: nil, httpStatus: 0, networkError: Offline())
        else { return XCTFail("сеть") }

        guard case .failure(.http(500)) = EntitlementClient.classify(
            data: "{}".data(using: .utf8), httpStatus: 500, networkError: nil)
        else { return XCTFail("500") }

        guard case .failure(.badResponse) = EntitlementClient.classify(
            data: "<html>".data(using: .utf8), httpStatus: 200, networkError: nil)
        else { return XCTFail("мусор") }

        let empty = try EntitlementClient.classify(
            data: "{\"guid\":\"g1\",\"grants\":[]}".data(using: .utf8),
            httpStatus: 200, networkError: nil
        ).get()
        XCTAssertTrue(empty.grants.isEmpty)
        XCTAssertFalse(empty.testMode)
        XCTAssertNil(empty.activeGrant)
    }

    func testNoActiveGrantMeansNilActiveGrant() throws {
        let body = "{\"guid\":\"g\",\"grants\":[{\"level\":\"x\",\"status\":\"revoked\"}]}"
        let snap = try EntitlementClient.classify(
            data: body.data(using: .utf8), httpStatus: 200, networkError: nil
        ).get()
        XCTAssertEqual(snap.grants.count, 1)
        XCTAssertNil(snap.activeGrant)
    }

    private func entitlementsSync() -> Result<Entitlements, EntitlementsError>? {
        let exp = expectation(description: "entitlements")
        var out: Result<Entitlements, EntitlementsError>?
        Web2App.entitlements { r in
            XCTAssertTrue(Thread.isMainThread)
            out = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        return out
    }

    func testNoGuidIsDistinctError() {
        Web2App.configure(projectId: "proj_test", baseUrl: URL(string: "http://127.0.0.1:9")!)
        Web2App.debugClear()
        guard case .failure(.noGuid) = entitlementsSync() else { return XCTFail("нет guid") }
    }

    /// Живой отказ соединения проходит через настоящий путь и даёт `.network`.
    func testRefusedConnectionIsNetworkError() {
        Web2App.configure(projectId: "proj_test", baseUrl: URL(string: "http://127.0.0.1:9")!)
        Web2App.debugSetGuid("g-net")
        defer { Web2App.debugClear() }
        guard case .failure(.network) = entitlementsSync() else { return XCTFail("сеть") }
    }
}
