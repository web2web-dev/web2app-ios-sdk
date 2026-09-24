import XCTest
@testable import Web2AppSDK

/// 0.8.0 — чистое ядро предзагрузки: URL фонового инстанса, правило
/// переиспользования, контракт сигнала показа. UIKit-кэш — на девайсе.
final class PaywallPreloadTests: XCTestCase {
    private func params(
        guid: String = "g1",
        email: String? = nil,
        adapty: String? = nil,
        revenuecat: String? = nil
    ) -> PaywallPreload.Params {
        PaywallPreload.Params(
            guid: guid, email: email, adaptyProfileId: adapty, revenuecatProfileId: revenuecat)
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testPreloadURLAddsPreloadFlagOnTopOfAppOriginParams() {
        let url = PaywallPreload.preloadURL(
            paywallURL: URL(string: "https://pay.example.com/p?pass=abc")!,
            params: params(email: "a@b.c", adapty: "ad1"))
        let q = query(url)
        XCTAssertEqual(q["preload"], "1")
        XCTAssertEqual(q["origin"], "app")
        XCTAssertEqual(q["guid"], "g1")
        XCTAssertEqual(q["email"], "a@b.c")
        XCTAssertEqual(q["adapty_profile_id"], "ad1")
        XCTAssertEqual(q["pass"], "abc", "исходный query пейвола сохраняется")
    }

    func testEmptyStringsEqualNotPassed() {
        XCTAssertEqual(params(email: "", adapty: "", revenuecat: ""), params())
    }

    func testReusableWhenSameParamsAndFresh() {
        let loadedAt = Date()
        XCTAssertTrue(
            PaywallPreload.isReusable(
                loadedWith: params(email: "a@b.c"), loadedAt: loadedAt,
                requested: params(email: "a@b.c"), now: loadedAt.addingTimeInterval(60)))
    }

    /// Страница загружена с другими email/profile-id/guid — показ по ней связал
    /// бы оплату не с тем, что просили. Такой инстанс не показывается.
    func testNotReusableWhenAnyParamDiffers() {
        let loadedAt = Date()
        let base = params(email: "a@b.c", adapty: "ad1")
        for other in [
            params(guid: "g2", email: "a@b.c", adapty: "ad1"),
            params(email: "x@b.c", adapty: "ad1"),
            params(email: "a@b.c"),
            params(email: "a@b.c", adapty: "ad1", revenuecat: "rc1"),
        ] {
            XCTAssertFalse(
                PaywallPreload.isReusable(
                    loadedWith: base, loadedAt: loadedAt, requested: other, now: loadedAt))
        }
    }

    func testNotReusableAfterMaxAge() {
        let loadedAt = Date()
        XCTAssertFalse(
            PaywallPreload.isReusable(
                loadedWith: params(), loadedAt: loadedAt, requested: params(),
                now: loadedAt.addingTimeInterval(PaywallPreload.maxAge)))
    }

    /// Контракт с вебом: имя события и флаг — их читает страница.
    func testShownScriptContract() {
        XCTAssertTrue(PaywallPreload.shownScript.contains("window.__web2appShown = true"))
        XCTAssertTrue(PaywallPreload.shownScript.contains("new Event('web2app:shown')"))
    }
}
