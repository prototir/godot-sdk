# Changelog

## Unreleased

- **Feedback & tools** for testers, with nothing to set up: Screenshot, Comment, Console and
  Performance. Web exports get the web SDK's control. Native builds get the same control in the
  bottom-left corner whenever the build knows its prototype: the performance chart records only
  while open, and a screenshot or log is always sent with a message. On Godot 4.5+ the console
  records `print()`, warnings and errors from start; on 4.3 and 4.4 it shows what the game sends
  through the new `Prototir.log()`. Turn it off with **prototir/feedback_tools** in Project
  Settings or `Prototir.set_feedback_tools(false)`; `Prototir.console_text()` returns the log.
- The bundled review runtime (web builds) now draws the feedback control like the Prototir badge
  and uses the website's current palette.

## 0.3.0 - 2026-09-30

- **Prototir: Publish to Prototir (Web)** and **(Native)** export, upload the ZIP straight to
  Prototir, and open the upload page (or the prototype's Studio page when the project has a slug)
  with the build waiting. The first time on a computer the editor is linked to your account with a
  browser approval; the link can only upload. **Prototir: Unlink This Editor** forgets it.
- The **Prototir** dock now asks what you are building, **Web** or **Native**, and shows only that
  target's checks. A native project is no longer told to use the Compatibility renderer or to add
  a Web export preset.
- "Download" is now "Native" wherever it names the kind of build: **Prototir: Export for Prototir
  (Native)** (was **(Download)**) and the docs.
- The export dialog now names the current upload page steps (**Add a build > Windows**).

## 0.2.1 - 2026-09-28

- Included the built-in pairing screen in an installable release, and reused an already-open screen.
- Added `show_feedback_screen()` for desktop text feedback: one comment, browser pairing when needed, drafts retained during this run, and retry IDs preventing duplicate comments.
- Browser captures now use the Prototir host composer through Web SDK 0.2.8.

- A downloadable build now tells Prototir which build it is at launch, so a download-only
  prototype switches on the first time anyone runs it. This used to require pairing, which
  asked a creator to link a build to their account before their own download counted for
  anything, and made every prototype a separate chore. Pairing is about identity; this is
  about which build is running, and they are now separate.
- A build that is not the uploaded one, or that carries no build id because it was zipped by
  hand, says so in the log rather than leaving a creator with a prototype that does nothing.

## 0.2.0 - 2026-09-21

- Added a native transport for downloadable builds: device-code pairing, a stored per-prototype
  token, one accumulated session per play, and comments posted as the tester who approved the build.
- A play in progress now reports itself every 30 seconds, and when the window loses focus.
  The only moment a session was ever sent was the next launch, so a tester who played once
  and never opened the build again reported nothing at all, which is the most common way a
  prototype gets tried.
- A session is reported with the exact fields the server's contract has: an always-present
  `"sessionId": ""` could not be parsed and made the endpoint answer 500, which the queue
  treats as retry-later, so every session piled up on disk and none were sent. An
  always-present `"score": 0` would also have scored every play that never scored.
- `configure()` now drains the session queue. The drain ran only in `_ready`, before a runtime
  `configure()` could say where to send, so a build that learned its prototype at runtime kept
  every session it ever recorded and sent none of them.
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
