# Changelog

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.0.0/),
проект следует семантическому версионированию (SemVer).

## [0.2.0] — 2026-07-23

### Added
- `Web2App.openWebPaywall(paywallURL:email:completion:)` — обратный флоу
  app→web-paywall: пользователь в приложении открывает веб-пейвол и после
  оплаты получает доступ. После закрытия пейвола SDK поллит entitlement и
  возвращает грант в completion (WEB-525).

## [0.1.0]

- Первый публичный релиз iOS SDK: `configure`, `identify(deepLinkValue:)`,
  `requestEmailRecovery`, `entitlement`, `currentGuid`.
