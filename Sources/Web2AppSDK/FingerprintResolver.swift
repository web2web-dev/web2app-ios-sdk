import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// WEB-1213 — опознание первого запуска по отпечатку устройства (аналог
/// Web2Wave `identify`). Закрывает единственный небесшовный сценарий:
/// iOS + установка ПОСЛЕ клика по возвратной ссылке + без MMP-трекера —
/// Universal Link через установку не переживает, Install Referrer у Apple нет.
///
/// Механика: веб-страница после оплаты в момент ухода в App Store отправила
/// на бэкенд сигналы (IP/UA — серверные; экран/таймзона/язык — клиентские).
/// Приложение на первом запуске шлёт СВОИ сигналы на
/// `POST /public/handoff/resolve-by-fingerprint`; бэкенд отвечает guid только
/// при единственном уверенном совпадении в окне (два кандидата на одном IP →
/// отказ обоим), иначе — унифицированный 404 и мы уходим в прежний
/// email-фолбэк. Отпечаток одноразовый.
///
/// PII не собирается: модель/версия ОС/экран/таймзона/язык — не required-reason
/// API и не идентификаторы рекламы (ни IDFA, ни IDFV).
struct FingerprintResolver {
    let config: Web2AppConfig

    /// Сигналы устройства. Экран — ЛОГИЧЕСКИЕ пункты, нормализованные к
    /// «min x max» (ориентация не должна рвать матч; сервер нормализует так же).
    struct Signals {
        let platform: String
        let osVersion: String
        let deviceModel: String?
        let screen: String
        let timezone: String
        let language: String?
    }

    static func collectSignals() -> Signals? {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        let w = Int(min(bounds.width, bounds.height))
        let h = Int(max(bounds.width, bounds.height))
        return Signals(
            platform: "ios",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: Self.machineIdentifier(),
            screen: "\(w)x\(h)",
            timezone: TimeZone.current.identifier,
            language: Locale.preferredLanguages.first
        )
        #else
        // Не-UIKit платформа (macOS юнит-тесты): сигналов экрана нет — путь
        // отпечатка честно пропускается, identify уходит в email-фолбэк.
        return nil
        #endif
    }

    /// Точная модель (`iPhone15,2`) через uname — Web2Wave-путь; НЕ является
    /// required-reason API и не идентифицирует устройство уникально.
    static func machineIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? nil : identifier
    }

    /// Резолв guid по отпечатку. Любой промах (нет совпадения, неоднозначно,
    /// протухло, выключено у проекта) приходит одинаковым 404 — наружу отдаём
    /// просто nil, и вызывающий уходит в email-фолбэк.
    func resolve(completion: @escaping (_ guid: String?, _ matchMethod: String?) -> Void) {
        guard let signals = Self.collectSignals() else { return completion(nil, nil) }

        let url = config.baseUrl
            .appendingPathComponent("public/handoff/resolve-by-fingerprint")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = [
            "projectId": config.projectId,
            "platform": signals.platform,
            "osVersion": signals.osVersion,
            "screen": signals.screen,
            "timezone": signals.timezone,
        ]
        if let model = signals.deviceModel { body["deviceModel"] = model }
        if let language = signals.language { body["language"] = language }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                SdkLogger.error("identify.fingerprint_network_error", err.localizedDescription)
                return completion(nil, nil)
            }
            guard
                let data,
                let parsed = Self.parseResolveResponse(data)
            else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // 404 = штатный промах (нет уверенного единственного совпадения).
                SdkLogger.log(
                    "identify.fingerprint_no_match",
                    context: ["http": String(code)])
                return completion(nil, nil)
            }
            completion(parsed.guid, parsed.matchMethod)
        }.resume()
    }

    /// Успех приходит обёрткой `{"success":true,"data":{"guid":…,"matchMethod":…}}`
    /// (та же форма, что у `public/handoff/resolve`). Мусор/тело ошибки → nil.
    static func parseResolveResponse(_ data: Data) -> (guid: String, matchMethod: String?)? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = obj["data"] as? [String: Any],
            let guid = payload["guid"] as? String,
            !guid.isEmpty
        else { return nil }
        return (guid, payload["matchMethod"] as? String)
    }
}
