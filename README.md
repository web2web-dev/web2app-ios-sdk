# web2app iOS SDK (скелет) — WEB-434

Тонкий iOS-SDK для P10-моста web→app. **IP наш, MIT.** Модель B+C (тонкая обвязка над
нашим backend, не полный native руками).

> ⚠ **Статус: СКЕЛЕТ до POC-1.** MMP-ветка (`deep_link_value` из callback) ship-blocked
> до POC-1 (реальный девайс + TestFlight + живой OneLink подтверждают доставку
> `deep_link_value`; adjust/ios_sdk#752, iOS17/18). Остальное (R1-passthrough,
> APP_INSTALLED, guid-persist, token/email-resolve) реализовано по контрактам backend.

## Установка (Swift Package Manager)
Xcode → **File → Add Package Dependencies** → URL:
```
https://github.com/web2web-dev/web2app-ios-sdk.git
```
Версия: `0.1.0` (Up to Next Major). Продукт: `Web2AppSDK`.

## API (4 точки, Web2Wave-стиль)
```swift
Web2App.configure(projectId: "proj_…", baseUrl: URL(string: "https://api.…")!)

// первый запуск: передать deep_link_value из СВОЕГО MMP-callback (POC-1) или nil
Web2App.identify(deepLinkValue: afDeepLinkValue) { result in … }   // → guid
// промах атрибуции → .needsEmailFallback → покажи экран email:
Web2App.requestEmailRecovery(email) { _ in }   // сервер шлёт magic-link (204)

// в любой момент:
Web2App.entitlement { grant in if grant?.isActive == true { unlock() } }  // R1 passthrough
```

## Принципы (WEB-428)
- `guid` = client-held ключ (Keychain), отдаём вам; `email` = recovery (verified).
- **Свой fingerprint НЕ строим** — на iOS портрет снимает MMP-SDK интегратора, не мы.
- Carrier = opaque token; `entitlement()` дословно проксирует наш R1 (не тронут).

## Backend-контракты (сверены с кодом)
| Точка | Метод |
|---|---|
| Entitlement (R1) | `GET /public/entitlement?guid=` → `{grants:[…]}` |
| App-installed | `POST /public/handoff/app-callback` → 204 |
| Token→guid | `GET /public/handoff/resolve?code=` → `{guid}` |
| Email-recovery | `POST /public/handoff/email-recovery/request` → 204 (magic-link) |

Privacy: `PrivacyInfo.xcprivacy` (App Functionality, НЕ Tracking) — в бандле.

## Android
Отдельный репо: https://github.com/web2web-dev/web2app-android-sdk
