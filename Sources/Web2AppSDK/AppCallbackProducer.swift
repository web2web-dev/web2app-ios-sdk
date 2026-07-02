import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// APP_INSTALLED-продюсер (закрывает Lucas-дыру «висячий хук»). На 1-м запуске любая
/// ветка резолва guid → `POST /public/handoff/app-callback` (метрика conversionToApp).
/// Идемпотентно на бэке (204). Grant НЕ зависит от этого callback — чисто метрика.
struct AppCallbackProducer {
    let config: Web2AppConfig

    func reportAppInstalled(guid: String) {
        let url = config.baseUrl.appendingPathComponent("public/handoff/app-callback")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Тело зеркалит AppCallbackDto: { guid, projectId, device, event }.
        let body: [String: String] = [
            "guid": guid,
            "projectId": config.projectId,
            "device": Self.platform,
            "event": "app_installed",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Fire-and-forget: сбой метрики НЕ ломает пользовательский поток.
        URLSession.shared.dataTask(with: req).resume()
    }

    /// device-строка для дедуп-ключа метрики (bounded whitelist на бэке: ios|android).
    static var platform: String { "ios" }
}
