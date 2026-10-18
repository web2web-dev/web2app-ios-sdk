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

// MARK: - Публичная поверхность с конфигурацией (приёмка WEB-3580, находки 1–3)

#if DEBUG
/// Записи журнала, пойманные наблюдателем `SdkLogger` (под замком: сетевые
/// ответы могут писать журнал с фонового потока).
private final class LogCapture {
    struct Entry { let event: String; let message: String; let context: [String: String] }
    private let lock = NSLock()
    private var items: [Entry] = []
    func add(_ e: Entry) { lock.lock(); items.append(e); lock.unlock() }
    var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return items }
    var events: [String] { entries.map(\.event) }
}

final class ConfiguredIdentifyTests: XCTestCase {
    private let saved = "653E4675-AAAA-BBBB-CCCC-000000000001"
    private var capture = LogCapture()

    override func setUp() {
        super.setUp()
        Web2App.clearGuid()
        capture = LogCapture()
        let capture = self.capture
        SdkLogger.debugSetObserver { event, message, context in
            capture.add(.init(event: event, message: message, context: context))
        }
        // Порт 9 закрыт — сетевые шаги отказывают сразу, без внешней сети.
        Web2App.configure(projectId: "proj_test", baseUrl: URL(string: "http://127.0.0.1:9")!)
    }

    override func tearDown() {
        SdkLogger.debugSetObserver(nil)
        Web2App.debugResetConfiguration()
        Web2App.clearGuid()
        super.tearDown()
    }

    private func assertNoGuidValue(file: StaticString = #filePath, line: UInt = #line) {
        for e in capture.entries {
            XCTAssertFalse(e.event.contains(saved), "guid in event \(e.event)", file: file, line: line)
            XCTAssertFalse(e.message.contains(saved), "guid in message of \(e.event)", file: file, line: line)
            for (k, v) in e.context {
                XCTAssertFalse(
                    k.contains(saved) || v.contains(saved), "guid in context of \(e.event)",
                    file: file, line: line)
            }
        }
    }

    /// Старая форма 0.8.1 после `configure` отдаёт сохранённый guid сразу и
    /// ничего не стирает.
    func testOldFormReturnsSavedGuidAndKeepsIt() {
        Web2App.debugSetGuid(saved)
        var result: Result<String, Web2AppError>?
        Web2App.identify(deepLinkValue: "tok") { result = $0 }
        guard case .success(let guid)? = result else {
            return XCTFail("expected synchronous success, got \(String(describing: result))")
        }
        XCTAssertEqual(guid, saved)
        XCTAssertEqual(Web2App.currentGuid(), saved)
        XCTAssertEqual(SdkLogger.shared.debugCurrentGuid(), saved)
        XCTAssertFalse(capture.events.contains("guid.cleared"))
        XCTAssertFalse(capture.events.contains("identify.forced"))
    }

    /// Новая форма с `force: false` — то же самое.
    func testForceFalseReturnsSavedGuidAndKeepsIt() {
        Web2App.debugSetGuid(saved)
        var result: Result<String, Web2AppError>?
        Web2App.identify(deepLinkValue: "tok", force: false) { result = $0 }
        guard case .success(let guid)? = result else {
            return XCTFail("expected synchronous success, got \(String(describing: result))")
        }
        XCTAssertEqual(guid, saved)
        XCTAssertEqual(Web2App.currentGuid(), saved)
        XCTAssertFalse(capture.events.contains("guid.cleared"))
    }

    /// `force: true` сохранённый guid не отдаёт: сброс через тот же путь, что
    /// `clearGuid()` (`identify.forced`, затем `guid.cleared` с `hadGuid=true`,
    /// guid журнала пуст), потом обычный путь — резолв токена (здесь сеть
    /// отказывает, значит ошибка, но не прежний guid).
    func testForceTrueClearsThroughSameResetAndProceeds() {
        Web2App.debugSetGuid(saved)
        SdkLogger.shared.setGuid(saved)
        let done = expectation(description: "identify completion")
        var result: Result<String, Web2AppError>?
        Web2App.identify(deepLinkValue: "tok", force: true) {
            result = $0
            done.fulfill()
        }
        XCTAssertNil(Web2App.currentGuid())
        XCTAssertNil(SdkLogger.shared.debugCurrentGuid())
        let events = capture.events
        let forced = events.firstIndex(of: "identify.forced")
        let cleared = events.firstIndex(of: "guid.cleared")
        XCTAssertNotNil(forced)
        XCTAssertNotNil(cleared)
        if let forced, let cleared { XCTAssertLessThan(forced, cleared) }
        XCTAssertEqual(
            capture.entries.first { $0.event == "guid.cleared" }?.context, ["hadGuid": "true"])
        XCTAssertTrue(events.contains("identify.resolving_token"))
        wait(for: [done], timeout: 20)
        if case .success(let guid)? = result { XCTAssertNotEqual(guid, saved) }
        XCTAssertNotEqual(Web2App.currentGuid(), saved)
        assertNoGuidValue()
    }

    /// `clearGuid()` пишет `guid.cleared` (`hadGuid=true`) без значения guid и
    /// очищает guid журнала: записи нового аккаунта не уйдут под прежним guid.
    func testClearGuidLogsAndEmptiesLoggerGuid() {
        Web2App.debugSetGuid(saved)
        SdkLogger.shared.setGuid(saved)
        XCTAssertEqual(SdkLogger.shared.debugCurrentGuid(), saved)
        Web2App.clearGuid()
        XCTAssertNil(SdkLogger.shared.debugCurrentGuid())
        XCTAssertEqual(
            capture.entries.filter { $0.event == "guid.cleared" }.map(\.context),
            [["hadGuid": "true"]])
        assertNoGuidValue()
    }

    /// Сбрасывать нечего — запись `hadGuid=false`, guid журнала не трогается.
    func testClearGuidWithoutGuidLogsHadGuidFalse() {
        Web2App.clearGuid()
        XCTAssertEqual(
            capture.entries.filter { $0.event == "guid.cleared" }.map(\.context),
            [["hadGuid": "false"]])
    }
}
#endif
