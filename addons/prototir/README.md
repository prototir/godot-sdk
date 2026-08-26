# Prototir SDK for Godot

Enable **Prototir SDK** under **Project Settings > Plugins**, then open the **Prototir** dock. The
dock validates the supported Godot Web profile, offers safe fixes, and the export guard writes
`prototir.json` next to a successful Web export.

Supported profile: Godot 4.3+, GDScript, Compatibility renderer, single-threaded Web export,
GDExtension and PWA disabled.

The Prototir sandbox supplies the Web protocol bridge. This addon does not use
`JavaScriptBridge.eval()` or require CSP `unsafe-eval`.

Complete documentation: https://prototir.com/docs/creators?runtime=godot#setup

Source and releases: https://github.com/prototir/godot-sdk
