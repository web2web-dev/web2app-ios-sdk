import Foundation

/// WEB-2479 доработка 3 — одно незавершённое ожидание оплаты `openWebPaywall`
/// (окно браузера). Ответ отдаётся ровно один раз: из опроса права
/// ([Web2App.startPaywallPolling]) или от возвратного метода ([offer], только
/// действующая запись — пустой ответ ожидание не закрывает).
final class PaywallWait {
    private let lock = NSLock()
    private var finished = false
    private let deliver: (EntitlementGrant?) -> Void

    init(deliver: @escaping (EntitlementGrant?) -> Void) {
        self.deliver = deliver
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Результат возвратного метода: действующая запись закрывает ожидание.
    func offer(_ grant: EntitlementGrant?) {
        guard let grant, grant.isActive else { return }
        finish(grant)
    }

    func finish(_ grant: EntitlementGrant?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        deliver(grant)
    }
}

extension Web2App {
    private static let paywallWaitsLock = NSLock()
    private static var paywallWaits: [ObjectIdentifier: PaywallWait] = [:]

    /// Регистрирует ожидание `openWebPaywall`; снимается при отдаче ответа.
    static func registerPaywallWait(
        deliver: @escaping (EntitlementGrant?) -> Void
    ) -> PaywallWait {
        var id: ObjectIdentifier?
        let wait = PaywallWait { grant in
            if let id {
                paywallWaitsLock.lock(); paywallWaits[id] = nil; paywallWaitsLock.unlock()
            }
            deliver(grant)
        }
        id = ObjectIdentifier(wait)
        paywallWaitsLock.lock(); paywallWaits[id!] = wait; paywallWaitsLock.unlock()
        return wait
    }

    static var pendingPaywallWaitCount: Int {
        paywallWaitsLock.lock(); defer { paywallWaitsLock.unlock() }
        return paywallWaits.count
    }

    /// Результат возвратного метода — во все незавершённые ожидания `openWebPaywall`.
    static func offerToPaywallWaits(_ grant: EntitlementGrant?) {
        paywallWaitsLock.lock()
        let waits = Array(paywallWaits.values)
        paywallWaitsLock.unlock()
        waits.forEach { $0.offer(grant) }
    }

    /// Опрос права для ожидания: guid берётся из хранилища на КАЖДОЙ попытке
    /// (возвратный метод мог обменять код и сменить guid), [fallbackGuid] — если
    /// хранилище пусто. Ожидание закрыто (ответ уже отдан) — опрос прекращается.
    static func startPaywallPolling(
        _ wait: PaywallWait,
        fallbackGuid: String,
        interval: TimeInterval,
        maxAttempts: Int,
        fetch: @escaping (String, @escaping (EntitlementGrant?) -> Void) -> Void
    ) {
        WebPaywallLauncher.pollForActiveGrant(
            interval: interval,
            maxAttempts: maxAttempts,
            fetch: { cb in fetch(currentGuid() ?? fallbackGuid, cb) },
            shouldContinue: { !wait.isFinished }
        ) { grant in
            wait.finish(grant)
        }
    }
}
