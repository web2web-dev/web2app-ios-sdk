import Foundation
import Security

/// guid = client-held ключ (WEB-428). Персист в Keychain (переживает переустановку хуже,
/// чем UserDefaults — но безопаснее; для steady-state entitlement по guid этого достаточно).
struct GuidStore {
    private let service = "app.web2app.sdk"
    private let account = "guid"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data,
            let guid = String(data: data, encoding: .utf8)
        else { return nil }
        return guid
    }

    func save(_ guid: String) {
        SecItemDelete(baseQuery as CFDictionary) // upsert: удалить старое, вставить новое
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(guid.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// Удаляет сохранённый guid (используется DEBUG-сбросом).
    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Временный guid неопознанного юзера — только под предзагрузку пейволов.
///
/// Лежит в UserDefaults, а НЕ в Keychain: `identify` читает только `GuidStore`,
/// поэтому временный guid не выдаёт себя за опознанного юзера — повторные
/// попытки по отпечатку и восстановление по email работают как без него.
/// Настоящим (в `GuidStore`) он становится только в момент показа страницы,
/// когда SDK и раньше создавал guid сам. Переживает перезапуск, чтобы страница
/// не связывала profile-id подписочной платформы с новым guid на каждом старте.
struct ProvisionalGuidStore {
    private let key = "app.web2app.sdk.provisionalGuid"

    func load() -> String? { UserDefaults.standard.string(forKey: key) }
    func save(_ guid: String) { UserDefaults.standard.set(guid, forKey: key) }
    func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
