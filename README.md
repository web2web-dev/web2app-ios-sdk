# web2app SDK (скелет) — WEB-434

Тонкий натив-SDK (Swift + Kotlin) для P10-моста web→app. **IP наш, MIT.** Модель B+C
(тонкая обвязка, не полный dual-native руками). Отдельный репозиторий — НЕ backend.

> ⚠ **Статус: СКЕЛЕТ до POC-1.** iOS MMP-ветка (`deep_link_value` из callback) —
> ship-blocked до POC-1 (реальный девайс + TestFlight + живой OneLink подтверждают,
> что `deep_link_value` доезжает; adjust/ios_sdk#752 iOS17/18 капризность). Стабильные
> части (R1-passthrough, APP_INSTALLED, guid-persist, token-resolve, email-fallback) —
> реализованы по контрактам backend; MMP-извлечение — интерфейс + POC-заглушка.

## Что делает SDK (4 точки, Web2Wave-стиль)

1. **`configure(projectId, baseUrl)`** — инициализация. `projectId` = ключ проекта арендатора.
2. **`entitlement()`** — passthrough к нашему R1: `GET {baseUrl}/public/entitlement?guid=<guid>`
   (R1 НЕ тронут, R2 = форк-обвязка). Возвращает грант; `grants[0].status == "active"` = доступ.
3. **`identify()`** — резолвит `guid` из источника атрибуции первого запуска:
   - **iOS:** MMP-callback (`onConversionDataSuccess` при `af_status=Non-organic`+`is_first_launch`
     / `adjustDeferredDeeplinkReceived`) → `deep_link_value` (= opaque token) → resolve → guid. **[POC-1]**
   - **Android:** Install Referrer (`com.android.installreferrer`) → `&referrer=<token>` → resolve → guid.
   - **email-fallback:** промах MMP/referrer (Huawei/sideload/органика) → экран email →
     verified-resolve (WEB-431) → guid. **НЕ падаем молча.**
4. **APP_INSTALLED-продюсер** — на 1-м запуске (любая ветка) шлём `POST {baseUrl}/public/handoff/app-callback`
   (метрика conversionToApp, 204, идемпотентно). Grant НЕ зависит от этого callback.

## Принципы (из WEB-428 маяка)

- **guid = client-held ключ** — отдаём вам; персист в Keychain(iOS)/EncryptedSharedPreferences(Android).
- **email = recovery** (детерминированный гарант, verified-канонизация).
- Свой fingerprint НЕ строим; на iOS портрет снимает MMP-SDK (не мы). MMP опционален.
- Carrier = opaque token (не сырой guid в публичных URL/MMP-логах).

## Privacy (App Review)

`PrivacyInfo.xcprivacy`: reason = **App Functionality**, НЕ Tracking (fingerprint не строим).
Talking-points для App Review — в поставке (см. `ios/PrivacyInfo.xcprivacy` + docs).

## Backend-контракты (стабильные, реализованы в скелете)

| Точка | Метод | Контракт |
|---|---|---|
| Entitlement (R1) | `GET /public/entitlement?guid=<guid>` | `{ guid, grants: [{ level, status, expires_at, price_id }] }` |
| App-installed | `POST /public/handoff/app-callback` | `{ guid, projectId, device, event: "app_installed" }` → 204 |
| Token→guid | `GET /public/handoff/resolve?code=<token>` | `{ guid, projectId }` (verified) |
| Email-recovery (шаг 1) | `POST /public/handoff/email-recovery/request` `{projectId,email}` | 204 (шлёт magic-link; guid НЕ здесь) |
| Email→guid (шаг 2) | юзер открыл magic-link → `code` → `GET /public/handoff/resolve?code=` | `{ guid }` (тот же resolve) |

## Структура

```
ios/       Swift Package (Sources/Web2AppSDK)
android/   Kotlin/Gradle (src/main/kotlin/app/web2app/sdk)
```

## Открытые пункты (не код-скелета)

- **POC-1** (iOS deep_link_value на реальном сторе) — гейт до ship iOS-ветки.
- **Call-контракт:** config-ключ (projectId vs publishable), формат токена (ffkey vs deep_link_value).
- **Variant C+ (pm_pending):** передача натив-среза + POC контрактору (design-partner #1); IP держим своим.
- Тест-харнесс: internal-track / adb-referrer-inject / staging-entitlement (built≠works).
