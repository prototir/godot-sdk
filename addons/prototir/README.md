# Prototir SDK for Godot

Enable **Prototir SDK** under **Project Settings > Plugins**, then open the **Prototir** dock. The
dock validates the supported Godot Web profile, offers safe fixes, and the export guard writes
`prototir.json` next to a successful Web export.

Supported profile: Godot 4.3+, GDScript, Compatibility renderer, single-threaded Web export,
GDExtension and PWA disabled.

Native Windows, macOS and Linux exports pair with a tester's account and report sessions over HTTP.

Testers get **Feedback & tools** (Screenshot, Comment, Console, Performance) with no code: on
Prototir the player draws it for Web exports, and native exports that know their prototype show it
in the bottom-left corner. `Prototir.set_feedback_tools(false)` or the `prototir/feedback_tools`
project setting hides it.

The dock tells you when a newer addon is released and installs it with one click.

The Prototir sandbox supplies the Web protocol bridge. This addon does not use
`JavaScriptBridge.eval()` or require CSP `unsafe-eval`.

Complete documentation: https://prototir.com/docs/creators?runtime=godot#setup

Source and releases: https://github.com/prototir/godot-sdk
