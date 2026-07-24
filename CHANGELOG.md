# Changelog

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.0.0/),
проект следует семантическому версионированию (SemVer).

## [0.4.0] — 2026-07-24

### Added
- `Web2App.openWebPaywall(paywallId:...)` — открытие пейвола по его ID:
  SDK сам резолвит публичный URL через `GET /public/paywall-url/:paywallId`.
- `Web2App.openWebPaywallEmbedded(paywallURL:/paywallId:...)` — встроенный
  WKWebView-режим с JS-мостом: при успехе оплаты пейвол закрывается
  автоматически, кнопка «Закрыть» обрабатывается без URL-схемы.
- `PaywallResult` — типизированный результат: `.paid(grant)` / `.notPaid` /
  `.pending` (вместо неоднозначного `EntitlementGrant?`).

## [0.3.0] — 2026-07-24

### Added
- `Web2App.handleReturnURL(_:)` — обработка возвратного deep-link'а кнопки
  «Закрыть» с веб-пейвола (`<схема>://handoff?code=...`): закрывает шторку
  SFSafariViewController и немедленно запускает guid-поллинг доступа —
  пользователь возвращается в приложение уже «платным». README: инструкция
  по регистрации URL-scheme и настройке «Схемы возврата» в кабинете.

## [0.2.0] — 2026-07-23

### Added
- `Web2App.openWebPaywall(paywallURL:email:completion:)` — обратный флоу
  app→web-paywall: пользователь в приложении открывает веб-пейвол и после
  оплаты получает доступ. После закрытия пейвола SDK поллит entitlement и
  возвращает грант в completion (WEB-525).

## [0.1.0]

- Первый публичный релиз iOS SDK: `configure`, `identify(deepLinkValue:)`,
  `requestEmailRecovery`, `entitlement`, `currentGuid`.
