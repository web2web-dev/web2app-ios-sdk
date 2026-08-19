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

Правило версии — **Up to Next Major**, начиная с `0.5.0`. Подключаемый продукт — `Web2AppSDK`.

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
//    deepLinkValue — токен из отложенного диплинка, который отдаёт ваш MMP-SDK
//    (AppsFlyer / Adjust). Берите его из поля `deep_link_sub1` (запасной дубль —
//    `af_sub1`), а НЕ из `deep_link_value`: там у нас константа `handoff`, и с ней
//    опознание молча не сработает. Если атрибуции нет — восстановление по email.
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

### Тестовый режим проекта

Если проект в кабинете переведён в тестовый режим, бэкенд отдаёт **синтетический**
грант: он выглядит активным (`isActive == true`), но помечен `testMode == true`.
Это не настоящая оплата — **не выдавайте по такому гранту боевой контент**:

```swift
Web2App.entitlement { grant in
    guard let grant, grant.isActive else { return lock() }
    if grant.testMode {
        // тестовый доступ: открывайте контент только в dev/QA-сборках
    } else {
        // боевой доступ
    }
}
```

У боевых грантов поле отсутствует или `false` — SDK декодирует его как `false`,
старые ответы без поля не ломаются.

### Где взять Project ID

В веб-кабинете: **проект → Настройки → «Подключение приложения» → «Полный мост»** —
там показан ваш Project ID (можно скопировать) и готовые сниппеты.

---

## API

| Метод | Назначение |
|---|---|
| `Web2App.configure(projectId:baseUrl:)` | Инициализация SDK. Вызвать один раз при старте. |
| `Web2App.identify(deepLinkValue:completion:)` | Опознать пользователя при первом запуске. Порядок: сохранённый `guid` → код из диплинка → **опознание по отпечатку устройства (0.7.0)** → сигнал «нужен email». |
| `Web2App.requestEmailRecovery(_:completion:)` | Запросить восстановление по email — мы отправим пользователю ссылку-магнит. |
| `Web2App.entitlement(completion:)` | Получить текущий доступ пользователя (`grant.isActive`, `level`, `status`, `expiresAt`, `testMode` — см. «Тестовый режим проекта»). |
| `Web2App.currentGuid()` | Текущий идентификатор пользователя (если уже опознан). |
| `Web2App.openWebPaywall(paywallURL:email:completion:)` | Показать веб-пейвол внутри приложения; completion вернёт активный доступ после оплаты (guid-поллинг). |
| `Web2App.handleReturnURL(_:)` | Обработать возвратный deep-link кнопки «Закрыть» с веб-пейвола (Safari-режим): закрывает шторку и ускоряет получение доступа. |
| `Web2App.openWebPaywall(paywallId:email:completion:)` | Открыть пейвол по его ID — публичный URL резолвится автоматически. |
| `Web2App.openWebPaywallEmbedded(paywallURL:/paywallId:email:completion:)` | Встроенный WebView-режим: авто-закрытие при успехе оплаты, результат — типизированный `PaywallResult` (paid / notPaid / pending / unavailable). URL-схема не нужна. |
| `Web2App.openQuizEmbedded(quizURL:email:completion:)` | Показать КВИЗ встроенным WebView. Результат — `QuizResult` (закрыт страницей / пользователем / оплатой). Права не поллит. |
| `Web2App.setFunnelEventListener(_:)` | Подписаться на события прохождения воронки из встроенного показа (`quiz_start`, `quiz_answer`, …). |

У методов открытия страницы есть ещё два опциональных параметра —
`adaptyProfileId:` и `revenuecatProfileId:` (см. «Adapty / RevenueCat» ниже).

Восстановление по email — два шага: `requestEmailRecovery(email)` отправляет пользователю
письмо со ссылкой; когда он по ней перейдёт, ваше приложение получит код из диплинка и
передаёт его снова в `identify(deepLinkValue: code)`.

### Опознание по отпечатку устройства (0.7.0)

Если приложение установлено ПОСЛЕ оплаты и трекера (AppsFlyer/Adjust) нет,
диплинк до приложения не доезжает — это ограничение Apple. С 0.7.0
`identify(deepLinkValue: nil)` в этом случае сам пробует опознание по
отпечатку: SDK отправляет сигналы устройства (версия iOS, модель, экран,
таймзона, язык) на наш бэкенд, который сравнивает их со слепком, оставленным
страницей после оплаты. `guid` возвращается только при **уверенном и
единственном** совпадении (два кандидата с одного IP — отказ обоим); любой
промах — прежний сигнал «нужен email», хуже не становится. Идентификаторы
рекламы (IDFA/IDFV) и запрос отслеживания (ATT) не используются. От вас
никаких новых вызовов не требуется.

### События прохождения воронки

Страница во встроенном WebView (`openWebPaywallEmbedded`, `openQuizEmbedded`) шлёт
SDK события прохождения. Подпишитесь один раз — и складывайте их в свою аналитику:

```swift
Web2App.setFunnelEventListener { name, data in
    // name: quiz_start | quiz_screen_view | quiz_answer | quiz_email_submit |
    //       quiz_complete | paywall_result | close
    analytics.log(name, [
        "screenId": data.screenId as Any,
        "screenIndex": data.screenIndex as Any,
        "screenTotal": data.screenTotal as Any,
        "blockId": data.blockId as Any,
        "blockType": data.blockType as Any,
    ])
}
// отписаться:
Web2App.setFunnelEventListener(nil)
```

- Колбэк приходит на **главный поток** — можно сразу трогать UI.
- Любое поле `FunnelEventData` может быть `nil` (зависит от события) — это норма.
- **PII в мост не уходит:** email и сырые тексты ответов страница вырезает у себя,
  до SDK доезжают только идентификаторы.
- **События воронки ничего не закрывают.** Показ завершают ровно два: успешная
  оплата (`paywall_result` со статусом `success`) и `close`. В частности,
  `quiz_complete` окно НЕ закрывает — после квиза страница часто сама ведёт на
  пейвол в том же WebView.
- Незнакомые события SDK молча игнорирует — новые имена на вебе ваше приложение
  не сломают.

### Квиз во встроенном WebView

```swift
Web2App.setFunnelEventListener { name, _ in analytics.log(name) }

Web2App.openQuizEmbedded(quizURL: URL(string: "https://client.example.com/q/quiz-1")!) { result in
    switch result {
    case .closed(.paid):    // внутри того же WebView прошла оплата
        Web2App.entitlement { grant in if grant?.isActive == true { unlock() } }
    case .closed(.page):    // страница попросила закрыть экран
        break
    case .closed(.user):    // пользователь нажал нативный крестик
        break
    case .unavailable:      // не вызван configure — экран не показывали
        break
    }
}
```

Отличия от пейвола: оплаты у квиза нет, поэтому SDK **не поллит право** и не
возвращает `PaywallResult` — наблюдаемое — это поток событий (в
`setFunnelEventListener`) плюс факт закрытия. Грант после `.closed(.paid)`
подтверждайте через `Web2App.entitlement`: подтверждение оплаты доезжает
вебхуком и может отставать на несколько секунд.

`quizURL` — **готовый** URL опубликованного квиза. Резолва «URL квиза по ID» на
бэкенде нет (он существует только для пейволов), поэтому открытия квиза по ID в
SDK нет.

### Adapty / RevenueCat: передать profile-id на страницу

Если подписки у вас на Adapty или RevenueCat — возьмите profile-id из их SDK
и передайте **оба** параметра в момент открытия страницы:

```swift
Web2App.openWebPaywallEmbedded(
    paywallURL: url,
    email: userEmail,
    adaptyProfileId: adaptyProfile.profileId,
    revenuecatProfileId: rcCustomerInfo.originalAppUserId
) { result in ... }
```

SDK допишет их в URL страницы параметрами `adapty_profile_id` /
`revenuecat_profile_id`. Пустые значения не отправляются. Параметры есть у всех
пяти методов открытия (`openWebPaywall` по URL и по ID, `openWebPaywallEmbedded`
по URL и по ID, `openQuizEmbedded`) и **опциональны** — существующие вызовы
менять не нужно.

**Как сервер пишет связку `guid` ↔ profile-id (важно).** Страница записывает
значение только в **пустой** слот. Если слот уже занят:

- заменить сохранённое значение через страницу **нельзя** — только серверной
  ручкой `POST /s2s/v1/identity/link-profile` (Bearer-ключ `sk_…`, право
  `identity:write`);
- дописать **вторую** платформу можно, только если в этом же открытии предъявлены
  верные значения всех уже занятых слотов.

Отсюда практическое правило: **передавайте оба идентификатора при каждом
открытии страницы** — тогда доказательство всегда при запросе, и вторая платформа
допишется. Полагаться на «сервер сам разберётся» нельзя.

⚠ **Отказ молчаливый.** Сервер отвечает «успех» в любом случае — так сделано,
чтобы по ответу нельзя было перебирать плательщиков. По ответу вы отказ не
увидите; он виден только в мониторинге на нашей стороне.

⚠ **Не используйте наш `guid` как profile-id подписочной платформы.** Если
приложение делало `Purchases.logIn(<наш guid>)` или `Adapty.identify(<наш guid>)`,
то предъявленное значение совпадёт с guid — такое доказательство сервер не
принимает, и дозапись второй платформы через страницу не сработает никогда.
Отдавайте платформам их собственный идентификатор пользователя.

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

### Настройка возврата: что передать владельцу воронки (WEB-802)

Чтобы возвратные ссылки (включая письмо после оплаты) открывали ваше
приложение, а не веб-страницу с кодом, владелец воронки вписывает в кабинете
(Настройки проекта → Подключение приложения → App ID) значение, которое даёте
вы:

- **iOS App ID** в формате `TeamID.BundleID`, например
  `ABCDE12345.com.example.app`. Team ID — Apple Developer → Membership;
  Bundle ID — Xcode → таргет → General → Bundle Identifier.

После сохранения файл `/.well-known/apple-app-site-association` на домене
возврата отдаёт ваш appID автоматически — выкладывать ничего не нужно. На
вашей стороне: включите Associated Domains
(`applinks:<projectId>.go.<домен>`) и обработайте входящий Universal Link
(пример ниже). Отдельно можно настроить схему возврата (`myapp://…`) для
кнопки «Закрыть» — см. раздел про `handleReturnURL` выше; схема дополняет
Universal Links, но не заменяет их: письмо открывается только по ним.

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
версия (`0.5.0`) — по интеграции атрибуции лучше согласоваться с нами.

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
