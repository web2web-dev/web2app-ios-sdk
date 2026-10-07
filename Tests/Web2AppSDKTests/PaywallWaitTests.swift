import XCTest
@testable import Web2AppSDK

/// WEB-2479 доработка 3 — ожидание оплаты `openWebPaywall` (окно браузера) на iOS.
///
/// Решение владельца 07.10: окно открыто, доступа по сохранённому guid нет, код в
/// ссылке есть → код обменивается и guid меняется. Доступ после этого обязан
/// получить И колбэк возвратного метода, И колбэк исходного `openWebPaywall` —
/// каждый ровно один раз (как на Android). До починки ожидание `openWebPaywall`
/// опрашивало право по guid, зафиксированному при показе, и отдавало «не оплачено».
final class PaywallWaitTests: XCTestCase {
    private static let active = EntitlementGrant(
        level: "l", status: "active", expiresAt: nil, priceId: "p")

    override func setUp() {
        super.setUp()
        Web2App.configure(projectId: "proj_test", baseUrl: URL(string: "http://127.0.0.1:9")!)
        Web2App.debugClear()
    }

    private let realExchanger = Web2App.codeExchanger
    private let realFetcher = Web2App.grantFetcher

    override func tearDown() {
        Web2App.codeExchanger = realExchanger
        Web2App.grantFetcher = realFetcher
        Web2App.debugClear()
        super.tearDown()
    }

    /// Ответ отдаётся один раз; пустой ответ возвратного метода ожидание не закрывает.
    func testWaitDeliversOnce() {
        var delivered: [EntitlementGrant?] = []
        let wait = PaywallWait { delivered.append($0) }
        wait.offer(nil)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertFalse(wait.isFinished)
        wait.offer(Self.active)
        wait.finish(nil)
        wait.offer(Self.active)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first??.isActive, true)
        XCTAssertTrue(wait.isFinished)
    }

    /// guid сменился посреди ожидания (обмен кода) → опрос идёт по НОВОМУ guid,
    /// и колбэк `openWebPaywall` получает доступ.
    func testPollFollowsGuidChangedByExchange() {
        Web2App.debugSetGuid("A")
        let lock = NSLock()
        var seen: [String] = []
        let exp = expectation(description: "delivered")
        var delivered: [EntitlementGrant?] = []
        let pending = Web2App.registerPaywallWait { grant in
            delivered.append(grant)
            exp.fulfill()
        }
        Web2App.startPaywallPolling(
            pending, fallbackGuid: "A", interval: 0.01, maxAttempts: 50,
            fetch: { guid, cb in
                lock.lock(); seen.append(guid); let n = seen.count; lock.unlock()
                if n == 2 { Web2App.debugSetGuid("B") } // обмен кода сменил guid
                cb(guid == "B" ? Self.active : nil)
            })
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first??.isActive, true)
        lock.lock(); XCTAssertEqual(seen.last, "B"); lock.unlock()
    }

    /// Результат возвратного метода уходит в незавершённое ожидание `openWebPaywall`;
    /// опрос после этого останавливается и второго колбэка нет.
    func testReturnResultIsOfferedToPendingWaitOnce() {
        var delivered: [EntitlementGrant?] = []
        let wait = Web2App.registerPaywallWait { delivered.append($0) }
        Web2App.offerToPaywallWaits(Self.active)
        XCTAssertEqual(delivered.count, 1)
        var fetches = 0
        Web2App.startPaywallPolling(
            wait, fallbackGuid: "A", interval: 0.01, maxAttempts: 5,
            fetch: { _, cb in fetches += 1; cb(nil) })
        XCTAssertEqual(fetches, 0)
        Web2App.offerToPaywallWaits(Self.active)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(Web2App.pendingPaywallWaitCount == 0)
    }

    /// Доработка 4, подключение: публичный `handleReturnURL` (сеть подменена) отдаёт
    /// результат и в незавершённое ожидание `openWebPaywall`, и в свой колбэк — по
    /// разу. На Linux окна нет, поэтому код обменивается и guid становится "B".
    func testHandleReturnURLDeliversToPendingPaywallWait() {
        Web2App.debugSetGuid("A")
        Web2App.codeExchanger = { _, _, cb in cb(.success("B"), 200) }
        var fetchedGuids: [String] = []
        let lock = NSLock()
        Web2App.grantFetcher = { _, guid, cb in
            lock.lock(); fetchedGuids.append(guid); lock.unlock()
            cb(guid == "B" ? Self.active : nil)
        }
        let waitExp = expectation(description: "paywall wait")
        var waitDelivered: [EntitlementGrant?] = []
        _ = Web2App.registerPaywallWait { grant in
            waitDelivered.append(grant)
            waitExp.fulfill()
        }
        let returnExp = expectation(description: "return")
        XCTAssertTrue(Web2App.handleReturnURL(URL(string: "myapp://handoff?code=K1")!) { grant in
            XCTAssertEqual(grant?.isActive, true)
            returnExp.fulfill()
        })
        wait(for: [waitExp, returnExp], timeout: 5)
        XCTAssertEqual(waitDelivered.count, 1)
        XCTAssertEqual(waitDelivered.first??.isActive, true)
        lock.lock(); XCTAssertEqual(fetchedGuids, ["B"]); lock.unlock()
        XCTAssertEqual(Web2App.pendingPaywallWaitCount, 0)
    }
}
