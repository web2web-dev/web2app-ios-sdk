# web2app iOS SDK

Тонкий SDK, который связывает вашу веб-воронку с мобильным приложением: пользователь
проходит воронку в вебе, устанавливает приложение — и приложение узнаёт, **кто это** и
**что он оплатил**, чтобы сразу открыть платный контент. Матчинг «воронка → установка»
делается на нашей стороне, вам не нужно писать его логику.

- Язык: Swift · Платформа: iOS 14+ · Лицензия: MIT
- Установка: Swift Package Manager

---

## Установка (Swift Package Manager)

В Xcode: **File → Add Package Dependencies…** и вставьте URL:

```
https://github.com/web2web-dev/web2app-ios-sdk.git
```

Правило версии — **Up to Next Major**, начиная с `0.1.0`. Подключаемый продукт — `Web2AppSDK`.

---

## Быстрый старт

Три шага. Больше для базовой интеграции ничего не нужно.

```swift
import Web2AppSDK

// 1. Инициализация — один раз при старте приложения.
Web2App.configure(
    projectId: "ВАШ_PROJECT_ID",                          // берётся в кабинете проекта
    baseUrl: URL(string: "https://api.testfunnelsdev.click")!
)

// 2. Идентификация пользователя при первом запуске.
//    deepLinkValue — значение, которое отдаёт ваш MMP-SDK (AppsFlyer / Adjust)
//    из отложенного диплинка. Если атрибуции нет — сработает восстановление по email.
Web2App.identify(deepLinkValue: attributionValue) { result in
    switch result {
    case .success(let guid):
        print("пользователь опознан: \(guid)")
    case .failure(.needsEmailFallback):
        // покажите экран «введите email» и вызовите requestEmailRecovery(...)
        break
    case .failure(let error):
        print("ошибка: \(error)")
    }
}

// 3. Проверка доступа — в любой момент, чтобы открыть/закрыть платный контент.
Web2App.entitlement { grant in
    if grant?.isActive == true {
        // разблокировать доступ
    }
}
```

### Где взять Project ID

В веб-кабинете: **проект → Настройки → «Подключение приложения» → «Полный мост»** —
там показан ваш Project ID (можно скопировать) и готовые сниппеты.

---

## API

| Метод | Назначение |
|---|---|
| `Web2App.configure(projectId:baseUrl:)` | Инициализация SDK. Вызвать один раз при старте. |
| `Web2App.identify(deepLinkValue:completion:)` | Опознать пользователя при первом запуске. Возвращает `guid` или сигнал «нужен email». |
| `Web2App.requestEmailRecovery(_:completion:)` | Запросить восстановление по email — мы отправим пользователю ссылку-магнит. |
| `Web2App.entitlement(completion:)` | Получить текущий доступ пользователя (`grant.isActive`, `level`, `status`, `expiresAt`). |
| `Web2App.currentGuid()` | Текущий идентификатор пользователя (если уже опознан). |
| `Web2App.openWebPaywall(paywallURL:email:completion:)` | Показать веб-пейвол внутри приложения; completion вернёт активный доступ после оплаты (guid-поллинг). |
| `Web2App.handleReturnURL(_:)` | Обработать возвратный deep-link кнопки «Закрыть» с веб-пейвола (Safari-режим): закрывает шторку и ускоряет получение доступа. |
| `Web2App.openWebPaywall(paywallId:email:completion:)` | Открыть пейвол по его ID — публичный URL резолвится автоматически. |
| `Web2App.openWebPaywallEmbedded(paywallURL:/paywallId:email:completion:)` | Встроенный WebView-режим: авто-закрытие при успехе оплаты, результат — типизированный `PaywallResult` (paid / notPaid / pending / unavailable). URL-схема не нужна. |

Восстановление по email — два шага: `requestEmailRecovery(email)` отправляет пользователю
письмо со ссылкой; когда он по ней перейдёт, ваше приложение получит код из диплинка и
передаёт его снова в `identify(deepLinkValue: code)`.

### Возврат из веб-пейвола кнопкой «Закрыть»

После оплаты на веб-пейволе пользователь видит экран «Доступ открыт» с маленькой
кнопкой «Закрыть». Чтобы она бесшовно возвращала в ваше приложение:

1. Зарегистрируйте custom URL-scheme приложения (`CFBundleURLTypes` в Info.plist),
   например `myapp`.
2. Укажите эту же схему в кабинете проекта (настройка «Схема возврата» /
   `bridgeConfig.returnScheme`) — наш сервер начнёт выдавать кнопке ссылку вида
   `myapp://handoff?code=...`.
3. Передавайте входящие URL в SDK из своего обработчика:

```swift
// AppDelegate
func application(_ app: UIApplication, open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if Web2App.handleReturnURL(url) { return true }
    // ... ваши остальные deep-link'и
    return false
}
```

SDK закроет шторку веб-пейвола и немедленно запустит проверку доступа — completion
исходного `openWebPaywall` получит активный грант, пользователь возвращается уже
«платным». Без регистрации схемы всё тоже работает: пользователь закрывает шторку
сам, доступ приходит тем же guid-поллингом.

### Ссылка из письма после оплаты (Universal Link)

После успешной оплаты покупателю приходит письмо со ссылкой вида
`https://<projectId>.go.<домен>/handoff/<КОД>` — одноразовый 8-символьный код в
пути. Если приложение привязано к этому домену (Associated Domains:
`applinks:<projectId>.go.<домен>`), iOS откроет приложение — обработчик пишете
вы (Universal Link приходит приложению, SDK перехватить его не может):

```swift
// SceneDelegate (UIKit)
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else { return }
    handleHandoffLink(url)
}

func handleHandoffLink(_ url: URL) {
    // pathComponents = ["/", "handoff", "<КОД>"]
    guard url.pathComponents.count >= 3,
          url.pathComponents[1] == "handoff" else { return }
    Web2App.identify(deepLinkValue: url.pathComponents[2]) { result in
        switch result {
        case .success:
            Web2App.entitlement { grant in
                DispatchQueue.main.async {
                    if grant?.isActive == true { /* открыть премиум */ }
                }
            }
        case .failure:
            // Код одноразовый (повторный тап = ошибка). guid уже мог быть
            // сохранён ранее — сперва проверьте entitlement, и только при
            // пустом ответе показывайте Web2App.requestEmailRecovery(email).
            break
        }
    }
}
```

```swift
// SwiftUI — та же обработка, другая точка входа
.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
    if let url = activity.webpageURL { handleHandoffLink(url) }
}
```

Не путать с кнопкой «Закрыть»: её ссылка — кастомная схема
`<схема>://handoff?code=...`, она обрабатывается `handleReturnURL(_:)` (выше) и
код намеренно не тратит. Ссылка из письма — Universal Link с кодом в пути, её
обрабатывает `identify(deepLinkValue:)` и код расходует.

---

## Как это работает

1. Пользователь проходит вашу веб-воронку — мы знаем, кто он и что оплатил.
2. Он переходит в App Store и ставит приложение. Идентификатор доезжает через отложенный
   диплинк вашего MMP (AppsFlyer / Adjust).
3. SDK при первом запуске опознаёт пользователя через наш сервер и связывает установку с
   вашим проектом.
4. `entitlement()` возвращает актуальный доступ — вы открываете платный контент.

---

## Приватность

- Идентификатор пользователя (`guid`) хранится в Keychain, никакой рекламный трекинг SDK
  сам не ведёт.
- В комплекте — privacy-манифест `PrivacyInfo.xcprivacy` (категория App Functionality).

## Требования к атрибуции (iOS)

Для сопоставления «воронка → установка» на iOS нужен ваш MMP-SDK (AppsFlyer или Adjust),
который передаёт значение отложенного диплинка в `identify(deepLinkValue:)`. Это ранняя
версия (`0.2.0`) — по интеграции атрибуции лучше согласоваться с нами.

---

## Android

Отдельный пакет: https://github.com/web2web-dev/web2app-android-sdk

## Безопасность: SDK ≠ серверные ключи

SDK работает ТОЛЬКО с публичным `projectId` — этого достаточно для распознавания
пользователя и проверки доступа с устройства. **Никогда не встраивайте серверный
API-ключ (`sk_live_…`) в приложение** — он даёт доступ к данным проекта и
предназначен только для server-to-server вызовов с вашего бэкенда. Про
S2S-аутентификацию (Bearer `sk_`, ручки `/s2s/v1/*`, входящие/исходящие вебхуки с
подписью) — см. раздел «Аутентификация» в документации для разработчиков
(dev-docs.html в кабинете проекта).

## Лицензия

MIT.
