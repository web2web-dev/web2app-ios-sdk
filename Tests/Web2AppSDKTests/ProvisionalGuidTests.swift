import XCTest
@testable import Web2AppSDK

// Жизнь guid вокруг предзагрузки (0.8.1). Файл трогает ТОЛЬКО типы из
// ProvisionalGuid.swift (чистый Foundation) — собирается и гоняется на Linux.

/// Настоящий guid в памяти вместо Keychain; считает записи.
private final class MemoryGuidStore: GuidStoring {
    var value: String?
    private(set) var saves = 0

    init(_ value: String? = nil) { self.value = value }

    func load() -> String? { value }
    func save(_ guid: String) {
        saves += 1
        value = guid
    }
    func clear() { value = nil }
}

/// Временный guid в памяти вместо UserDefaults.
private final class MemoryProvisionalStore: ProvisionalGuidStoring {
    var value: ProvisionalGuid?

    init(_ value: ProvisionalGuid? = nil) { self.value = value }

    func load() -> ProvisionalGuid? { value }
    func save(_ record: ProvisionalGuid) { value = record }
    func clear() { value = nil }
}

private func record(
    _ guid: String, adapty: String? = nil, revenuecat: String? = nil
) -> ProvisionalGuid {
    ProvisionalGuid(guid: guid, adaptyProfileId: adapty, revenuecatProfileId: revenuecat)
}

// MARK: - Хранилище временного guid (UserDefaults)

final class ProvisionalGuidStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "web2app.tests.provisional.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEmptyStoreLoadsNil() {
        XCTAssertNil(ProvisionalGuidStore(defaults: defaults).load())
    }

    /// guid и обе привязки к профилю переживают запись и чтение (новый экземпляр
    /// хранилища — как после перезапуска приложения).
    func testSaveThenLoadKeepsGuidAndProfiles() {
        ProvisionalGuidStore(defaults: defaults)
            .save(record("P", adapty: "a1", revenuecat: "r1"))
        XCTAssertEqual(
            ProvisionalGuidStore(defaults: defaults).load(),
            record("P", adapty: "a1", revenuecat: "r1"))
    }

    func testSaveWithoutProfilesLoadsNilProfiles() {
        let store = ProvisionalGuidStore(defaults: defaults)
        store.save(record("P"))
        let loaded = store.load()
        XCTAssertEqual(loaded?.guid, "P")
        XCTAssertNil(loaded?.adaptyProfileId)
        XCTAssertNil(loaded?.revenuecatProfileId)
    }

    func testClearRemovesGuidAndProfiles() {
        let store = ProvisionalGuidStore(defaults: defaults)
        store.save(record("P", adapty: "a1"))
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(forKey: ProvisionalGuidStore.key))
    }

    /// Пустая строка profile-id = «не передали» — не превращается в привязку.
    func testEmptyProfileStringsAreNotBindings() {
        XCTAssertEqual(record("P", adapty: "", revenuecat: ""), record("P"))
    }
}

// MARK: - Правило guid для фоновой загрузки

final class GuidRulesPreloadTests: XCTestCase {
    private func decide(
        saved: String? = nil, provisional: ProvisionalGuid? = nil,
        adapty: String? = nil, revenuecat: String? = nil,
        mint: () -> String = { "new" }
    ) -> GuidRules.PreloadDecision {
        GuidRules.preload(
            saved: saved, provisional: provisional,
            adaptyProfileId: adapty, revenuecatProfileId: revenuecat, mint: mint)
    }

    func testSavedGuidWinsAndNothingIsMintedOrStored() {
        var minted = false
        let d = decide(
            saved: "saved", provisional: record("P", adapty: "a1"), adapty: "b1",
            mint: { minted = true; return "new" })
        XCTAssertEqual(d, GuidRules.PreloadDecision(guid: "saved", source: .saved, store: nil))
        XCTAssertFalse(minted)
    }

    /// Органика на втором запуске, тот же профиль: тот же временный guid,
    /// а не новый на каждом старте.
    func testSameProfileReusesProvisional() {
        var minted = false
        let d = decide(
            provisional: record("P", adapty: "a1", revenuecat: "r1"),
            adapty: "a1", revenuecat: "r1", mint: { minted = true; return "new" })
        XCTAssertEqual(d, GuidRules.PreloadDecision(guid: "P", source: .provisional, store: nil))
        XCTAssertFalse(minted)
    }

    func testNoProvisionalMintsOneBoundToPassedProfiles() {
        let d = decide(adapty: "a1", revenuecat: "r1")
        XCTAssertEqual(
            d,
            GuidRules.PreloadDecision(
                guid: "new", source: .minted, store: record("new", adapty: "a1", revenuecat: "r1")))
    }

    /// Починка 3: вход в другой аккаунт Adapty — новый временный guid, а не старый,
    /// который сервер уже связал с прежним профилем.
    func testOtherAdaptyProfileReissuesProvisional() {
        let d = decide(provisional: record("P", adapty: "a1"), adapty: "b1", mint: { "P2" })
        XCTAssertEqual(
            d,
            GuidRules.PreloadDecision(guid: "P2", source: .reissued, store: record("P2", adapty: "b1")))
    }

    func testOtherRevenuecatProfileReissuesProvisional() {
        let d = decide(
            provisional: record("P", adapty: "a1", revenuecat: "r1"),
            adapty: "a1", revenuecat: "r2", mint: { "P2" })
        XCTAssertEqual(d.guid, "P2")
        XCTAssertEqual(d.source, .reissued)
        XCTAssertEqual(d.store, record("P2", adapty: "a1", revenuecat: "r2"))
    }

    /// Решение по брифу: profile-id не передан (nil или пусто) — это не смена профиля.
    func testMissingProfileIsNotAChange() {
        var minted = false
        let stored = record("P", adapty: "a1", revenuecat: "r1")
        for (adapty, revenuecat) in [(nil, nil), ("", ""), ("a1", nil), (nil, "r1")] as [(String?, String?)] {
            let d = decide(
                provisional: stored, adapty: adapty, revenuecat: revenuecat,
                mint: { minted = true; return "new" })
            XCTAssertEqual(d, GuidRules.PreloadDecision(guid: "P", source: .provisional, store: nil))
        }
        XCTAssertFalse(minted)
    }

    /// Временный создан без profile-id, теперь profile-id передан — guid тот же,
    /// привязка дописывается (чтобы следующий ДРУГОЙ профиль уже считался сменой).
    func testEmptyBindingIsFilledWithoutNewGuid() {
        let d = decide(provisional: record("P", adapty: "a1"), revenuecat: "r1")
        XCTAssertEqual(
            d,
            GuidRules.PreloadDecision(
                guid: "P", source: .provisional, store: record("P", adapty: "a1", revenuecat: "r1")))
    }
}

// MARK: - Правило guid для показа

final class GuidRulesShowTests: XCTestCase {
    private func decide(
        saved: String? = nil, provisional: ProvisionalGuid? = nil,
        adapty: String? = nil, revenuecat: String? = nil
    ) -> GuidRules.ShowDecision {
        GuidRules.show(
            saved: saved, provisional: provisional,
            adaptyProfileId: adapty, revenuecatProfileId: revenuecat, mint: { "new" })
    }

    func testSavedWinsOverProvisional() {
        XCTAssertEqual(
            decide(saved: "saved", provisional: record("P", adapty: "a1"), adapty: "b1"),
            GuidRules.ShowDecision(guid: "saved", persist: false, discardedProvisional: false))
    }

    /// Показ у органики берёт тот guid, под который загружены фоновые страницы.
    func testSameProfileAdoptsProvisional() {
        XCTAssertEqual(
            decide(provisional: record("P", adapty: "a1"), adapty: "a1"),
            GuidRules.ShowDecision(guid: "P", persist: true, discardedProvisional: false))
    }

    /// Показ без profile-id (например, квиз) берёт временный как есть.
    func testShowWithoutProfileAdoptsProvisional() {
        XCTAssertEqual(
            decide(provisional: record("P", adapty: "a1", revenuecat: "r1")),
            GuidRules.ShowDecision(guid: "P", persist: true, discardedProvisional: false))
    }

    /// Починка 3: временный привязан к другому профилю, чем передан в показ, —
    /// настоящим он не становится, чеканится новый.
    func testOtherProfileDiscardsProvisionalAndMints() {
        XCTAssertEqual(
            decide(provisional: record("P", adapty: "a1"), adapty: "b1"),
            GuidRules.ShowDecision(guid: "new", persist: true, discardedProvisional: true))
        XCTAssertEqual(
            decide(provisional: record("P", revenuecat: "r1"), revenuecat: "r2").guid, "new")
    }

    func testNothingStoredMints() {
        XCTAssertEqual(
            decide(),
            GuidRules.ShowDecision(guid: "new", persist: true, discardedProvisional: false))
    }
}

// MARK: - Жизненный цикл поверх хранилищ

final class GuidLifecycleTests: XCTestCase {
    private func lifecycle(
        _ real: MemoryGuidStore, _ provisional: MemoryProvisionalStore, mint: String = "new"
    ) -> GuidLifecycle {
        GuidLifecycle(real: real, provisional: provisional, mint: { mint })
    }

    /// Предзагрузка НИКОГДА не пишет настоящий guid: иначе `identify` счёл бы
    /// пользователя опознанным и не пошёл бы по отпечатку и email.
    func testPreloadStoresProvisionalOnlyAndNeverRealGuid() {
        let real = MemoryGuidStore()
        let provisional = MemoryProvisionalStore()
        let d = lifecycle(real, provisional).preload(adaptyProfileId: "a1", revenuecatProfileId: nil)
        XCTAssertEqual(d.guid, "new")
        XCTAssertEqual(provisional.value, record("new", adapty: "a1"))
        XCTAssertNil(real.value)
        XCTAssertEqual(real.saves, 0)
    }

    func testPreloadReissueReplacesStoredProvisional() {
        let real = MemoryGuidStore()
        let provisional = MemoryProvisionalStore(record("P", adapty: "a1"))
        let d = lifecycle(real, provisional, mint: "P2")
            .preload(adaptyProfileId: "b1", revenuecatProfileId: nil)
        XCTAssertEqual(d.source, .reissued)
        XCTAssertEqual(provisional.value, record("P2", adapty: "b1"))
        XCTAssertNil(real.value)
    }

    /// Показ переносит временный guid в настоящий и стирает временный.
    func testShowMovesProvisionalToRealAndClearsIt() {
        let real = MemoryGuidStore()
        let provisional = MemoryProvisionalStore(record("P", adapty: "a1"))
        let d = lifecycle(real, provisional).adoptForShow(adaptyProfileId: "a1", revenuecatProfileId: nil)
        XCTAssertEqual(d.guid, "P")
        XCTAssertEqual(real.value, "P")
        XCTAssertNil(provisional.value)
    }

    /// Настоящий guid показ не перезаписывает; временный всё равно стирается.
    func testShowWithRealGuidDoesNotRewriteItAndClearsProvisional() {
        let real = MemoryGuidStore("G")
        let provisional = MemoryProvisionalStore(record("P"))
        let d = lifecycle(real, provisional).adoptForShow(adaptyProfileId: nil, revenuecatProfileId: nil)
        XCTAssertEqual(d.guid, "G")
        XCTAssertEqual(real.value, "G")
        XCTAssertEqual(real.saves, 0)
        XCTAssertNil(provisional.value)
    }

    func testShowWithOtherProfileMakesFreshGuidReal() {
        let real = MemoryGuidStore()
        let provisional = MemoryProvisionalStore(record("P", adapty: "a1"))
        let d = lifecycle(real, provisional, mint: "X").adoptForShow(adaptyProfileId: "b1", revenuecatProfileId: nil)
        XCTAssertEqual(d.guid, "X")
        XCTAssertEqual(real.value, "X")
        XCTAssertNil(provisional.value)
    }

    /// Опознание: guid пользователя — настоящий, временный стёрт.
    func testIdentifiedSavesRealAndClearsProvisional() {
        let real = MemoryGuidStore()
        let provisional = MemoryProvisionalStore(record("P", adapty: "a1"))
        lifecycle(real, provisional).identified("G")
        XCTAssertEqual(real.value, "G")
        XCTAssertNil(provisional.value)
    }

    func testPreloadedPagesGuidPrefersRealThenProvisional() {
        XCTAssertEqual(
            lifecycle(MemoryGuidStore("G"), MemoryProvisionalStore(record("P"))).guidForPreloadedPages(),
            "G")
        XCTAssertEqual(
            lifecycle(MemoryGuidStore(), MemoryProvisionalStore(record("P"))).guidForPreloadedPages(),
            "P")
        XCTAssertNil(lifecycle(MemoryGuidStore(), MemoryProvisionalStore()).guidForPreloadedPages())
    }
}

// MARK: - Какие страницы перегрузить при смене guid

final class GuidRulesReloadTests: XCTestCase {
    /// Перегружаются только загруженные страницы из набора, загруженные под
    /// другой guid. Под тем же guid, ещё не загруженные и выкинутые из набора —
    /// не трогаются.
    func testReloadsOnlyRequestedLoadedPagesWithOtherGuid() {
        let ids = GuidRules.pagesToReload(
            requested: ["pw_b", "pw_same", "pw_loading", "pw_a"],
            loadedGuids: ["pw_a": "P", "pw_b": "P", "pw_same": "G", "pw_gone": "P"],
            currentGuid: "G")
        XCTAssertEqual(ids, ["pw_a", "pw_b"])
    }

    func testNothingToReloadWhenGuidUnchanged() {
        XCTAssertEqual(
            GuidRules.pagesToReload(
                requested: ["pw_a"], loadedGuids: ["pw_a": "G"], currentGuid: "G"),
            [])
    }
}
