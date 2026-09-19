# Changelog

## Unreleased

- Added a native transport for downloadable builds: device-code pairing, a stored per-prototype
  token, one accumulated session per play, and comments posted as the tester who approved the build.
- Added `Prototir.configure`, `is_paired`, `begin_pairing`, `cancel_pairing`, `unpair`,
  `send_feedback` and `flush_session`, plus the `pairing_started`, `pairing_succeeded` and
  `pairing_failed` signals.
- Added **Prototir: Export for Prototir (Web)** and **(Download)** to Project > Tools. Both export,
  zip the result, and keep the unused transport out of the pack through the preset exclude filter.
- Added `prototir/prototype_slug`, `prototir/api_base_url` and `prototir/device_label` project
  settings.
- Added headless runtime tests (`tests/run_tests.gd`) and a CI job that runs them in Godot.

## 0.1.0 - 2026-08-26

- Initial public Godot 4 Web integration for Prototir protocol version 1.
- Added readiness, analytics events, scores, persistent storage, and managed text generation.
- Added Editor and native mocks with correlated asynchronous request objects.
- Added a Project Setup dock, safe fixes, export diagnostics, and manifest generation.
- Added a CSP-safe JavaScript bridge and structural export validator.
