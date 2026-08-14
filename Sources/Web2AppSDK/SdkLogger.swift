import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Удалённый журнал SDK: каждый внутренний шаг (configure / identify / резолв
/// токена / чтение права / пейвол / события моста / ошибки сети) пачками
/// отправляется на наш бэкенд `POST /public/sdk-logs`. Без него единственный
/// способ понять, что происходит внутри приложения интегратора, — просить его
/// снять логи Xcode.
///
/// Правила:
///  - **Никогда не ломает SDK.** Отправка fire-and-forget; сбой сети — молча.
///  - **PII не уходит.** Email не логируется (только факт «email передан»);
///    guid — наш собственный client-held идентификатор.
///  - До `configure` записи копятся в буфере и уезжают после конфигурации.
///  - Буфер ограничен (старые записи вытесняются), пачка ≤ 50 записей —
///    зеркало серверного капа (`ArrayMaxSize(50)` в SdkLogBatchDto).
final class SdkLogger {
    static let shared = SdkLogger()

    /// Версия SDK — уезжает в каждую пачку журнала.
    static let sdkVersion = "0.7.1"

    /// Серийная очередь — единственный владелец мутируемого состояния ниже.
    private let queue = DispatchQueue(label: "com.web2app.sdk-logger")
    private var config: Web2AppConfig?
    private var guid: String?
    private var buffer: [[String: Any]] = []
    private var flushScheduled = false

    /// Кап буфера: телеметрия не имеет права копить память без предела.
    private let maxBufferedEntries = 200
    /// Зеркало серверного `ArrayMaxSize(50)` — больше сервер отверг бы целиком.
    private let batchLimit = 50
    /// Дебаунс отправки: соседние шаги склеиваются в одну пачку.
    private let flushDelay: TimeInterval = 3.0

    private init() {}

    // MARK: публичные (внутри модуля) точки

    /// Вызывается из `Web2App.configure` — с этого момента журнал может уезжать.
    func attach(_ config: Web2AppConfig) {
        queue.async {
            self.config = config
            self.scheduleFlushLocked()
        }
    }

    /// guid резолвлен/зачеканен — включается во все последующие пачки.
    func setGuid(_ guid: String) {
        queue.async { self.guid = guid }
    }

    static func log(
        _ event: String,
        _ message: String = "",
        context: [String: String] = [:],
        level: String = "info"
    ) {
        shared.append(event: event, message: message, context: context, level: level)
    }

    static func error(
        _ event: String,
        _ message: String = "",
        context: [String: String] = [:]
    ) {
        log(event, message, context: context, level: "error")
    }

    // MARK: буфер и отправка

    private func append(
        event: String, message: String, context: [String: String], level: String
    ) {
        // Локальная видимость в Xcode-консоли интегратора — тем же ходом.
        print("[Web2App] \(level.uppercased()) \(event)"
            + (message.isEmpty ? "" : " — \(message)")
            + (context.isEmpty ? "" : " \(context)"))

        queue.async {
            var entry: [String: Any] = [
                "ts": Int64(Date().timeIntervalSince1970 * 1000),
                "level": level,
                "event": String(event.prefix(128)),
            ]
            if !message.isEmpty { entry["message"] = String(message.prefix(2000)) }
            if !context.isEmpty { entry["context"] = context }
            self.buffer.append(entry)
            if self.buffer.count > self.maxBufferedEntries {
                self.buffer.removeFirst(self.buffer.count - self.maxBufferedEntries)
            }
            self.scheduleFlushLocked()
        }
    }

    /// Только с `queue`. Планирует одну отправку с дебаунсом.
    private func scheduleFlushLocked() {
        guard config != nil, !buffer.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + flushDelay) { self.flushLocked() }
    }

    /// Только с `queue`. Снимает пачку с буфера и шлёт fire-and-forget.
    private func flushLocked() {
        flushScheduled = false
        guard let config, !buffer.isEmpty else { return }
        let batch = Array(buffer.prefix(batchLimit))
        buffer.removeFirst(batch.count)

        var body: [String: Any] = [
            "projectId": config.projectId,
            "platform": "ios",
            "sdkVersion": Self.sdkVersion,
            "device": Self.deviceInfo,
            "entries": batch,
        ]
        if let guid { body["guid"] = guid }

        var req = URLRequest(
            url: config.baseUrl.appendingPathComponent("public/sdk-logs"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Сбой отправки — молча: журнал вспомогательный, записи не возвращаем
        // в буфер (иначе мёртвая сеть раздувала бы его бесконечными ретраями).
        URLSession.shared.dataTask(with: req).resume()

        scheduleFlushLocked() // остались записи → следующая пачка
    }

    /// Модель/ОС/версия приложения — контекст каждой пачки.
    private static let deviceInfo: [String: String] = {
        var info: [String: String] = [:]
        #if canImport(UIKit)
        info["model"] = UIDevice.current.model
        info["os"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        info["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        let main = Bundle.main
        if let bundleId = main.bundleIdentifier { info["bundleId"] = bundleId }
        if let appVersion = main.infoDictionary?["CFBundleShortVersionString"] as? String {
            info["appVersion"] = appVersion
        }
        return info
    }()
}
