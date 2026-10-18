import XCTest
@testable import Web2AppSDK

// Публичный сброс guid (0.9.0): `Web2App.clearGuid()` и `identify(force:)`.
// Решения о guid проверяются в ProvisionalGuidTests (GuidLifecycleResetTests);
// здесь — публичная поверхность поверх настоящего хранилища guid. Тесты не
// зовут `configure`: состояние `Web2App` общее, а соседние тесты проверяют
// поведение без конфигурации.

#if DEBUG
final class ClearGuidTests: XCTestCase {
    override func tearDown() {
        Web2App.clearGuid()
        super.tearDown()
    }

    /// После сброса `currentGuid()` пуст, `entitlement` отвечает как у неопознанного.
    func testClearGuidErasesCurrentGuid() {
        Web2App.debugSetGuid("653E4675")
        XCTAssertEqual(Web2App.currentGuid(), "653E4675")
        Web2App.clearGuid()
        XCTAssertNil(Web2App.currentGuid())
        var called = false
        Web2App.entitlement { grant in
            called = true
            XCTAssertNil(grant)
        }
        XCTAssertTrue(called)
    }

    /// Повторный сброс и сброс без guid — без ошибок.
    func testClearGuidTwiceAndWithoutGuid() {
        Web2App.clearGuid()
        Web2App.clearGuid()
        XCTAssertNil(Web2App.currentGuid())
    }

    /// `debugClear` идёт тем же сбросом.
    func testDebugClearErasesGuid() {
        Web2App.debugSetGuid("653E4675")
        Web2App.debugClear()
        XCTAssertNil(Web2App.currentGuid())
    }

    /// Старый вызов без `force` собирается без правок (хвостовым замыканием и
    /// с меткой `completion:`).
    func testIdentifyWithoutForceStillCompiles() {
        var results: [Result<String, Web2AppError>] = []
        Web2App.identify(deepLinkValue: nil) { results.append($0) }
        Web2App.identify(deepLinkValue: "tok", completion: { results.append($0) })
        XCTAssertEqual(results.count, 2)
    }

    /// Старая форма 0.8.1 передаётся как значение (ссылка на функцию без вызова)
    /// и собирается: для этого есть отдельная перегрузка без `force`.
    func testOldIdentifyFormIsAssignableAsValue() {
        let f: (String?, @escaping (Result<String, Web2AppError>) -> Void) -> Void =
            Web2App.identify
        let g = Web2App.identify(deepLinkValue:completion:)
        var results: [Result<String, Web2AppError>] = []
        f(nil) { results.append($0) }
        g("tok") { results.append($0) }
        XCTAssertEqual(results.count, 2)
    }

    /// Новая форма с `force` тоже передаётся как значение.
    func testNewIdentifyFormIsAssignableAsValue() {
        let h: (String?, Bool, @escaping (Result<String, Web2AppError>) -> Void) -> Void =
            Web2App.identify
        var result: Result<String, Web2AppError>?
        h("tok", false) { result = $0 }
        XCTAssertNotNil(result)
    }

    /// Без `configure` `identify(force: true)` ничего не стирает: отказ
    /// `notConfigured` раньше сброса, как и любые другие шаги опознания.
    func testForcedIdentifyWithoutConfigureKeepsGuid() {
        Web2App.debugSetGuid("653E4675")
        var result: Result<String, Web2AppError>?
        Web2App.identify(deepLinkValue: "tok", force: true) { result = $0 }
        guard case .failure(.notConfigured)? = result else {
            return XCTFail("expected notConfigured, got \(String(describing: result))")
        }
        XCTAssertEqual(Web2App.currentGuid(), "653E4675")
    }
}
#endif
