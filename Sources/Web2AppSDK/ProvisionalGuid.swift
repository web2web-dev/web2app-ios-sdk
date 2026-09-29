import Foundation

// Жизнь guid вокруг предзагрузки пейволов (0.8.1): временный guid неопознанного
// пользователя, перенос в настоящий при показе, стирание при опознании и при
// выгрузке предзагрузки, привязка временного guid к профилю подписочной платформы.
//
// Файл НАМЕРЕННО только на Foundation: без Security/UIKit/WebKit и без обращений
// к `GuidStore`, `SdkLogger`, `Web2App`. Хранилища — через протоколы, чтобы тест
// подставил хранилище в памяти, а SDK — Keychain и UserDefaults. Журнал пишет
// вызывающий код по возвращённому решению.

// MARK: - Хранилища

/// Настоящий guid. В SDK — Keychain (`GuidStore`), в тесте — память.
protocol GuidStoring {
    func load() -> String?
    func save(_ guid: String)
    func clear()
}

/// Временный guid и профили подписочных платформ, под которые он создан.
///
/// Зачем профили: страница при загрузке пишет на сервер связку «guid ↔ profile-id»,
/// а занятое поле публичная ручка сервера не перезаписывает никогда. Если профиль
/// сменился (вход в аккаунт, другой пользователь), старый временный guid остался бы
/// привязан к прежнему профилю — и оплата ушла бы туда.
struct ProvisionalGuid: Equatable {
    let guid: String
    let adaptyProfileId: String?
    let revenuecatProfileId: String?

    /// Пустая строка = «не передали» — то же правило, что в `PaywallPreload.Params`.
    init(guid: String, adaptyProfileId: String?, revenuecatProfileId: String?) {
        self.guid = guid
        self.adaptyProfileId = Self.nonEmpty(adaptyProfileId)
        self.revenuecatProfileId = Self.nonEmpty(revenuecatProfileId)
    }

    /// Привязан ли к ДРУГОМУ профилю, чем передан: хотя бы по одной платформе
    /// и записано, и передано непустое значение, и они разные. Не передан
    /// profile-id (nil или пусто) — это не смена профиля.
    func isBoundToOtherProfile(adaptyProfileId: String?, revenuecatProfileId: String?) -> Bool {
        Self.differs(stored: self.adaptyProfileId, passed: adaptyProfileId)
            || Self.differs(stored: self.revenuecatProfileId, passed: revenuecatProfileId)
    }

    /// Дописать переданные profile-id в пустые места; занятые не меняются.
    func filling(adaptyProfileId: String?, revenuecatProfileId: String?) -> ProvisionalGuid {
        ProvisionalGuid(
            guid: guid,
            adaptyProfileId: self.adaptyProfileId ?? Self.nonEmpty(adaptyProfileId),
            revenuecatProfileId: self.revenuecatProfileId ?? Self.nonEmpty(revenuecatProfileId))
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func differs(stored: String?, passed: String?) -> Bool {
        guard let stored, let passed = nonEmpty(passed) else { return false }
        return stored != passed
    }
}

/// Хранилище временного guid. В SDK — UserDefaults (`ProvisionalGuidStore`).
protocol ProvisionalGuidStoring {
    func load() -> ProvisionalGuid?
    func save(_ record: ProvisionalGuid)
    func clear()
}

/// Временный guid неопознанного пользователя — только под предзагрузку пейволов.
///
/// Лежит в UserDefaults, а НЕ в Keychain: `identify` читает только настоящий guid,
/// поэтому временный не выдаёт себя за опознанного пользователя — повторные
/// попытки по отпечатку и восстановление по email работают как без него.
/// Настоящим он становится только в момент показа страницы, когда SDK и раньше
/// создавал guid сам. Переживает перезапуск, чтобы страница не связывала
/// profile-id подписочной платформы с новым guid на каждом старте.
///
/// Одна запись под одним ключом (словарь): guid и профили пишутся и стираются
/// вместе, половинчатого состояния не бывает.
struct ProvisionalGuidStore: ProvisionalGuidStoring {
    static let key = "app.web2app.sdk.provisionalGuid"
    private static let fieldGuid = "guid"
    private static let fieldAdapty = "adaptyProfileId"
    private static let fieldRevenuecat = "revenuecatProfileId"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ProvisionalGuid? {
        guard
            let dict = defaults.dictionary(forKey: Self.key),
            let guid = dict[Self.fieldGuid] as? String,
            !guid.isEmpty
        else { return nil }
        return ProvisionalGuid(
            guid: guid,
            adaptyProfileId: dict[Self.fieldAdapty] as? String,
            revenuecatProfileId: dict[Self.fieldRevenuecat] as? String)
    }

    func save(_ record: ProvisionalGuid) {
        var dict: [String: String] = [Self.fieldGuid: record.guid]
        if let adapty = record.adaptyProfileId { dict[Self.fieldAdapty] = adapty }
        if let revenuecat = record.revenuecatProfileId { dict[Self.fieldRevenuecat] = revenuecat }
        defaults.set(dict, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: - Правила (чистые функции)

enum GuidRules {
    /// Откуда guid для фоновой загрузки.
    enum PreloadSource: Equatable {
        /// Настоящий (Keychain) — пользователь опознан или уже открывал страницу.
        case saved
        /// Прежний временный — привязан к тому же профилю (или профиль не передан).
        case provisional
        /// Временного не было — создан новый.
        case minted
        /// Прежний временный привязан к другому профилю — выпущен новый вместо него.
        case reissued
    }

    struct PreloadDecision: Equatable {
        let guid: String
        let source: PreloadSource
        /// Что записать во временное хранилище; nil — ничего не менять.
        let store: ProvisionalGuid?
    }

    /// guid для фоновой загрузки.
    /// - Есть настоящий — он; временное хранилище не трогается.
    /// - Есть временный, привязанный к тому же профилю (или profile-id не передан) —
    ///   он; переданные profile-id дописываются в пустые места привязки.
    /// - Временный привязан к ДРУГОМУ непустому profile-id (любой из двух платформ) —
    ///   выпускается новый временный вместо старого: у временного guid покупок нет,
    ///   менять его можно без потерь.
    /// - Временного нет — создаётся новый.
    static func preload(
        saved: String?,
        provisional: ProvisionalGuid?,
        adaptyProfileId: String?,
        revenuecatProfileId: String?,
        mint: () -> String
    ) -> PreloadDecision {
        if let saved {
            return PreloadDecision(guid: saved, source: .saved, store: nil)
        }
        if let provisional {
            if !provisional.isBoundToOtherProfile(
                adaptyProfileId: adaptyProfileId, revenuecatProfileId: revenuecatProfileId)
            {
                let filled = provisional.filling(
                    adaptyProfileId: adaptyProfileId, revenuecatProfileId: revenuecatProfileId)
                return PreloadDecision(
                    guid: provisional.guid, source: .provisional,
                    store: filled == provisional ? nil : filled)
            }
            let fresh = ProvisionalGuid(
                guid: mint(), adaptyProfileId: adaptyProfileId,
                revenuecatProfileId: revenuecatProfileId)
            return PreloadDecision(guid: fresh.guid, source: .reissued, store: fresh)
        }
        let fresh = ProvisionalGuid(
            guid: mint(), adaptyProfileId: adaptyProfileId, revenuecatProfileId: revenuecatProfileId)
        return PreloadDecision(guid: fresh.guid, source: .minted, store: fresh)
    }

    struct ShowDecision: Equatable {
        /// guid показа — он же уходит в опрос доступа.
        let guid: String
        /// Записать guid в настоящее хранилище (его там ещё нет).
        let persist: Bool
        /// Временный guid был, но привязан к другому профилю — не взят.
        let discardedProvisional: Bool
    }

    /// guid в момент показа — тот, что станет настоящим.
    /// - Есть настоящий — он (Keychain эта логика не меняет).
    /// - Есть временный и он НЕ привязан к другому профилю, чем передан в показ, — он:
    ///   под него уже загружены фоновые страницы. Показ без profile-id (например, квиз)
    ///   берёт временный как есть.
    /// - Иначе — новый, как было до предзагрузки.
    static func show(
        saved: String?,
        provisional: ProvisionalGuid?,
        adaptyProfileId: String?,
        revenuecatProfileId: String?,
        mint: () -> String
    ) -> ShowDecision {
        if let saved {
            return ShowDecision(guid: saved, persist: false, discardedProvisional: false)
        }
        if let provisional,
            !provisional.isBoundToOtherProfile(
                adaptyProfileId: adaptyProfileId, revenuecatProfileId: revenuecatProfileId)
        {
            return ShowDecision(guid: provisional.guid, persist: true, discardedProvisional: false)
        }
        return ShowDecision(
            guid: mint(), persist: true, discardedProvisional: provisional != nil)
    }

    /// Можно ли показать взятую из кэша страницу. guid, под который она загружена
    /// (он в адресе страницы, на него страница оформит оплату), обязан совпасть с
    /// guid показа (по нему идёт опрос доступа). Не совпали — например, между
    /// поиском в кэше и показом `identify` записал другой guid или временный
    /// оказался привязан к другому профилю — страницу не показывать, показ идёт
    /// обычным путём.
    static func mayShowPreloaded(pageGuid: String, shownGuid: String) -> Bool {
        pageGuid == shownGuid
    }

    /// Какие предзагруженные страницы перегрузить, когда guid сменился (опознали
    /// пользователя): те, что в наборе предзагрузки, уже загружены и загружены под
    /// ДРУГОЙ guid. Страницы, которые ещё грузятся (нет в `loadedGuids`), возьмут
    /// guid в момент загрузки сами. Результат отсортирован — порядок не случаен.
    static func pagesToReload(
        requested: [String],
        loadedGuids: [String: String],
        currentGuid: String
    ) -> [String] {
        requested
            .filter { id in loadedGuids[id].map { $0 != currentGuid } ?? false }
            .sorted()
    }
}

// MARK: - Жизненный цикл guid поверх хранилищ

/// Все записи и стирания guid вокруг предзагрузки — в одном месте, поверх
/// хранилищ через протокол. `Web2App` зовёт эти методы и пишет журнал по ответу.
struct GuidLifecycle {
    let real: GuidStoring
    let provisional: ProvisionalGuidStoring
    let mint: () -> String

    /// guid для фоновой загрузки; новый временный (или его дописанная привязка)
    /// сохраняется. Настоящее хранилище не трогается никогда.
    func preload(adaptyProfileId: String?, revenuecatProfileId: String?) -> GuidRules.PreloadDecision {
        let decision = GuidRules.preload(
            saved: real.load(), provisional: provisional.load(),
            adaptyProfileId: adaptyProfileId, revenuecatProfileId: revenuecatProfileId,
            mint: mint)
        if let record = decision.store { provisional.save(record) }
        return decision
    }

    /// guid показа: становится настоящим (если настоящего ещё нет), временный стирается.
    func adoptForShow(adaptyProfileId: String?, revenuecatProfileId: String?) -> GuidRules.ShowDecision {
        let decision = GuidRules.show(
            saved: real.load(), provisional: provisional.load(),
            adaptyProfileId: adaptyProfileId, revenuecatProfileId: revenuecatProfileId,
            mint: mint)
        if decision.persist { real.save(decision.guid) }
        provisional.clear()
        return decision
    }

    /// Пользователя опознали (`identify`): его guid — настоящий, временный больше не нужен.
    func identified(_ guid: String) {
        real.save(guid)
        provisional.clear()
    }

    /// guid, под который загружены (или грузятся) фоновые страницы: настоящий,
    /// иначе временный; nil — ни того, ни другого.
    func guidForPreloadedPages() -> String? {
        real.load() ?? provisional.load()?.guid
    }

    /// Стереть временный guid. Настоящий не трогается.
    func clearProvisional() {
        provisional.clear()
    }
}
