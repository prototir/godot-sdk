# Changelog

## Unreleased

- Added a native transport for downloadable builds: device-code pairing, a stored per-prototype
  token, one accumulated session per play, and comments posted as the tester who approved the build.
- Added an on-disk session queue: a play is written down when the window closes and sent at the
  next launch, so closing the game or being offline no longer loses it.
- Added `Prototir.configure`, `is_paired`, `begin_pairing`, `cancel_pairing`, `unpair`,
  `send_feedback` and `flush_session`, plus the `pairing_started`, `pairing_succeeded` and
  `pairing_failed` signals.
- Added **Prototir: Export for Prototir (Web)** and **(Download)** to Project > Tools. Both export,
  zip the result, and keep the unused transport out of the pack through the preset exclude filter.
- Added `prototir/prototype_slug`, `prototir/api_base_url` and `prototir/device_label` project
  settings. The endpoint defaults to `https://api.prototir.com/api`; `prototir.com/api` serves
  no `/api` path, so a downloadable build could not reach Prototir at all.
- Added a pairing example (`examples/pairing/`): a working pairing screen in one script,
  building its own UI in code, including opening the approval page and copying the code.
  A game window has no selectable text, so a printed URL on its own leaves the tester
  retyping it off a screen.
- Added headless runtime tests (`tests/run_tests.gd`) and a CI job that runs them in Godot,
  plus a smoke run of every example scene, which is the only check that sees the autoload.

## 0.1.0 - 2026-08-26

- Initial public Godot 4 Web integration for Prototir protocol version 1.
- Added readiness, analytics events, scores, persistent storage, and managed text generation.
- Added Editor and native mocks with correlated asynchronous request objects.
- Added a Project Setup dock, safe fixes, export diagnostics, and manifest generation.
- Added a CSP-safe JavaScript bridge and structural export validator.
