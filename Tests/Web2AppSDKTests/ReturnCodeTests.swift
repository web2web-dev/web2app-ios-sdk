import XCTest
@testable import Web2AppSDK

/// WEB-2479 — код из ссылки возврата обменивается, даже если guid уже сохранён;
/// возвратный метод обменивает код, когда окна библиотеки нет.
///
/// Решения владельца 06.10: (1) код погашен/просрочен (сервер 404), а сохранённый
/// guid есть → успех с сохранённым guid, не ошибка; сбой сети — ошибка `network`;
/// (2) код тратится только когда окна оплаты библиотеки нет.
final class ReturnCodeTests: XCTestCase {
    private let realExchanger = Web2App.codeExchanger

    override func setUp() {
        super.setUp()
        Web2App.configure(projectId: "proj_test", baseUrl: URL(string: "http://127.0.0.1:9")!)
        Web2App.debugClear()
    }

    override func tearDown() {
        Web2App.codeExchanger = realExchanger
        Web2App.debugClear()
        super.tearDown()
    }

    /// Подменяет обмен кода: отдаёт заданный ответ и считает вызовы.
    private func stubExchange(
        _ result: Result<String, Web2AppError>, http: Int
    ) -> () -> [String] {
        var seen: [String] = []
        let lock = NSLock()
        Web2App.codeExchanger = { _, code, cb in
            lock.lock(); seen.append(code); lock.unlock()
            cb(result, http)
        }
        return { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private func identifySync(_ value: String?) -> Result<String, Web2AppError>? {
        let exp = expectation(description: "identify")
        var out: Result<String, Web2AppError>?
        Web2App.identify(deepLinkValue: value) { r in
            out = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        return out
    }

    // MARK: правила (чистые функции)

    func testOutcomeExchangedOnSuccess() {
        guard case .exchanged(let g) = ReturnCodeRules.outcome(
            .success("B"), httpStatus: 200, cachedGuid: "A")
        else { return XCTFail("ожидался обмен") }
        XCTAssertEqual(g, "B")
    }

    func testOutcomeKeepsCachedGuidWhenCodeRejected() {
        guard case .keptCached(let g) = ReturnCodeRules.outcome(
            .failure(.resolveFailed), httpStatus: 404, cachedGuid: "A")
        else { return XCTFail("ожидался сохранённый guid") }
        XCTAssertEqual(g, "A")
    }

    func testOutcomeFailsWhenCodeRejectedAndNothingCached() {
        guard case .failed(.resolveFailed) = ReturnCodeRules.outcome(
            .failure(.resolveFailed), httpStatus: 404, cachedGuid: nil)
        else { return XCTFail("ожидалась ошибка") }
    }

    /// Сбой сети — НЕ отказ сервера: покупатель с оплатой под новым кодом не должен
    /// молча получить старый guid.
    func testOutcomeNetworkErrorIsNotMaskedByCachedGuid() {
        guard case .failed(.network) = ReturnCodeRules.outcome(
            .failure(.network("offline")), httpStatus: 0, cachedGuid: "A")
        else { return XCTFail("ожидалась ошибка сети") }
    }

    /// Ответ сервера 5xx/429 — тоже не «код погашен».
    func testOutcomeServerErrorIsNotMaskedByCachedGuid() {
        for status in [500, 502, 429] {
            guard case .failed(.resolveFailed) = ReturnCodeRules.outcome(
                .failure(.resolveFailed), httpStatus: status, cachedGuid: "A")
            else { return XCTFail("ожидалась ошибка для \(status)") }
        }
    }

    func testCodeFromReturnURL() {
        XCTAssertEqual(
            ReturnCodeRules.code(fromReturnURL: URL(string: "myapp://handoff?code=AB12")!), "AB12")
        XCTAssertEqual(
            ReturnCodeRules.code(fromReturnURL: URL(string: "myapp://handoff?x=1&code=c%2B1")!),
            "c+1")
        XCTAssertNil(ReturnCodeRules.code(fromReturnURL: URL(string: "myapp://handoff")!))
        XCTAssertNil(ReturnCodeRules.code(fromReturnURL: URL(string: "myapp://handoff?code=")!))
    }

    // MARK: identify(deepLinkValue:) — пункт 1

    /// Сохранён A, передан код, сервер отдаёт B → B, в хранилище B.
    /// До починки возвращался A без обмена.
    func testIdentifyWithCodeExchangesEvenWhenGuidCached() {
        Web2App.debugSetGuid("A")
        let seen = stubExchange(.success("B"), http: 200)
        let r = identifySync("code-1")
        XCTAssertEqual(try r?.get(), "B")
        XCTAssertEqual(Web2App.currentGuid(), "B")
        XCTAssertEqual(seen(), ["code-1"])
    }

    /// Код отвергнут сервером (404), сохранён A → успех с A, хранилище не тронуто.
    func testIdentifyWithRejectedCodeKeepsCachedGuid() {
        Web2App.debugSetGuid("A")
        _ = stubExchange(.failure(.resolveFailed), http: 404)
        let r = identifySync("used-code")
        XCTAssertEqual(try r?.get(), "A")
        XCTAssertEqual(Web2App.currentGuid(), "A")
    }

    /// Сбой сети при сохранённом A → ошибка network, A на месте.
    func testIdentifyWithCodeNetworkErrorFails() {
        Web2App.debugSetGuid("A")
        _ = stubExchange(.failure(.network("offline")), http: 0)
        let r = identifySync("code-2")
        guard case .failure(.network) = r else { return XCTFail("ожидалась ошибка сети") }
        XCTAssertEqual(Web2App.currentGuid(), "A")
    }

    /// Без кода при сохранённом A → A без сетевого запроса (как раньше).
    func testIdentifyWithoutCodeReturnsCachedWithoutNetwork() {
        Web2App.debugSetGuid("A")
        let seen = stubExchange(.success("B"), http: 200)
        XCTAssertEqual(try identifySync(nil)?.get(), "A")
        XCTAssertEqual(try identifySync("")?.get(), "A")
        XCTAssertEqual(seen(), [])
    }

    // MARK: возвратный метод — пункт 2

    private static let active = EntitlementGrant(
        level: "l", status: "active", expiresAt: nil, priceId: "p")
    private static let expired = EntitlementGrant(
        level: "l", status: "expired", expiresAt: nil, priceId: "p")

    private func runFlow(
        windowOpen: Bool, code: String?, exchange: CodeExchangeOutcome = .exchanged("B"),
        checkResult: EntitlementGrant? = ReturnCodeTests.active
    ) -> (dismissed: Int, exchanged: [String], checks: Int, polls: Int, results: [EntitlementGrant?]) {
        var dismissed = 0
        var exchanged: [String] = []
        var checks = 0
        var polls = 0
        var results: [EntitlementGrant?] = []
        let flow = ReturnURLFlow(
            windowOpen: windowOpen,
            dismissWindow: { dismissed += 1 },
            exchange: { c, cb in exchanged.append(c); cb(exchange) },
            checkStoredGuid: { cb in checks += 1; cb(checkResult) },
            pollStoredGuid: { cb in polls += 1; cb(ReturnCodeTests.active) })
        flow.run(code: code) { results.append($0) }
        return (dismissed, exchanged, checks, polls, results)
    }

    /// Окна нет, код есть → обмен, затем проверка права, результат один раз.
    /// До починки: код не обменивался вовсе.
    func testReturnWithoutWindowExchangesCode() {
        let r = runFlow(windowOpen: false, code: "X")
        XCTAssertEqual(r.dismissed, 0)
        XCTAssertEqual(r.exchanged, ["X"])
        XCTAssertEqual(r.polls, 1)
        XCTAssertEqual(r.results.count, 1)
        XCTAssertEqual(r.results.first??.isActive, true)
    }

    /// Окно библиотеки открыто и по сохранённому guid есть действующая запись →
    /// закрытие, код не тратится.
    func testReturnWithOpenWindowDoesNotSpendCode() {
        let r = runFlow(windowOpen: true, code: "X")
        XCTAssertEqual(r.dismissed, 1)
        XCTAssertEqual(r.exchanged, [])
        XCTAssertEqual(r.checks, 1)
        XCTAssertEqual(r.results.count, 1)
        XCTAssertEqual(r.results.first??.isActive, true)
    }

    /// Решение владельца 07.10: окно открыто, но действующей записи по сохранённому
    /// guid нет (бросил окно, оплатил в обычном браузере), код в ссылке есть →
    /// закрыть окно, обменять код, право по новому guid.
    func testReturnWithOpenWindowAndNoActiveGrantExchangesCode() {
        let r = runFlow(windowOpen: true, code: "X", checkResult: nil)
        XCTAssertEqual(r.dismissed, 1)
        XCTAssertEqual(r.exchanged, ["X"])
        XCTAssertEqual(r.polls, 1)
        XCTAssertEqual(r.results.count, 1)
        XCTAssertEqual(r.results.first??.isActive, true)
    }

    /// Неактивная запись — тоже «доступа нет»: код обменивается.
    func testReturnWithOpenWindowAndOnlyInactiveGrantExchangesCode() {
        let r = runFlow(windowOpen: true, code: "X", checkResult: ReturnCodeTests.expired)
        XCTAssertEqual(r.exchanged, ["X"])
        XCTAssertEqual(r.results.count, 1)
    }

    /// Окно открыто, доступа нет, обмен не удался → ответ проверки, один раз.
    func testReturnWithOpenWindowNoGrantFailedExchangeDeliversOnce() {
        let r = runFlow(
            windowOpen: true, code: "X", exchange: .failed(.network("x")), checkResult: nil)
        XCTAssertEqual(r.exchanged, ["X"])
        XCTAssertEqual(r.polls, 0)
        XCTAssertEqual(r.results.count, 1)
        XCTAssertNil(r.results.first!)
    }

    /// Окно открыто, кода в адресе нет → закрытие и право по сохранённому guid.
    func testReturnWithOpenWindowWithoutCodePollsStoredGuid() {
        let r = runFlow(windowOpen: true, code: nil)
        XCTAssertEqual(r.dismissed, 1)
        XCTAssertEqual(r.exchanged, [])
        XCTAssertEqual(r.checks, 0)
        XCTAssertEqual(r.polls, 1)
        XCTAssertEqual(r.results.count, 1)
    }

    /// Обмен не удался (сеть / код погашен без сохранённого guid) → nil, право не спрашиваем.
    func testReturnExchangeFailureDeliversNilOnce() {
        let r = runFlow(windowOpen: false, code: "X", exchange: .failed(.network("x")))
        XCTAssertEqual(r.polls, 0)
        XCTAssertEqual(r.results.count, 1)
        XCTAssertNil(r.results.first!)
    }

    /// Код погашен, но guid сохранён → право по сохранённому guid.
    func testReturnRejectedCodeWithCachedGuidChecksEntitlement() {
        let r = runFlow(windowOpen: false, code: "X", exchange: .keptCached("A"))
        XCTAssertEqual(r.polls, 1)
        XCTAssertEqual(r.results.count, 1)
    }

    /// Адрес без кода и без окна → право по сохранённому guid, обмена нет.
    func testReturnWithoutCodeChecksStoredGuid() {
        let r = runFlow(windowOpen: false, code: nil)
        XCTAssertEqual(r.exchanged, [])
        XCTAssertEqual(r.polls, 1)
        XCTAssertEqual(r.results.count, 1)
    }

    /// Публичный метод с колбэком: окна нет (на этой платформе окна не бывает) →
    /// код обменивается, guid сменился. Чужой адрес → false, колбэка нет.
    func testHandleReturnURLWithCompletionExchangesCode() {
        Web2App.debugSetGuid("A")
        let seen = stubExchange(.success("B"), http: 200)
        let exp = expectation(description: "return")
        let handled = Web2App.handleReturnURL(URL(string: "myapp://handoff?code=K1")!) { _ in
            exp.fulfill()
        }
        XCTAssertTrue(handled)
        wait(for: [exp], timeout: 15)
        XCTAssertEqual(seen(), ["K1"])
        XCTAssertEqual(Web2App.currentGuid(), "B")

        var foreignCalls = 0
        XCTAssertFalse(Web2App.handleReturnURL(URL(string: "myapp://settings")!) { _ in
            foreignCalls += 1
        })
        XCTAssertEqual(foreignCalls, 0)
    }
}
