# Prototir SDK for Godot

The official Godot integration for prototypes hosted on [Prototir](https://prototir.com). The addon
connects a Godot Web export to Prototir lifecycle signals, analytics events, scores, persistent
storage, and managed text generation. Its editor dock also checks project and export settings so
unsupported builds are caught before upload.

## Compatibility

- Godot 4.3 or newer
- GDScript and the Compatibility renderer
- Single-threaded Web export using the standard runtime profile

## Install

Download the `addons/prototir` directory from the
[v0.1.0 release](https://github.com/prototir/godot-sdk/releases/tag/v0.1.0) and copy it into your
project. Then:

1. Enable **Prototir SDK** under **Project Settings > Plugins**.
2. Open the **Prototir** dock.
3. Apply safe fixes and resolve every blocking item.
4. Export a non-debug Web build and ZIP the contents of the export directory.

The addon installs `Prototir` as an autoload. If you install source from `main` before the first
tag, pin the release tag once it becomes available.

## Basic use

```gdscript
Prototir.ready()
Prototir.event("level_complete", {"level": 2})
Prototir.score(1200)

var storage_request := Prototir.storage_get("difficulty")
var difficulty = await storage_request.completed
```

Managed AI requests expose explicit success and failure signals:

```gdscript
var request := Prototir.ai_generate("Give the player a short quest hook.", 80)
request.completed.connect(func(text): print(text))
request.failed.connect(func(code, message): push_warning("%s: %s" % [code, message]))
```

Call `ready()` after the first genuinely interactive frame. Event names are normalized to lowercase
and accept letters, numbers, `_`, `.`, `:`, and `-`. Keep payloads small and free of personal data.

## Project Setup and export checks

The dock checks the Godot version, renderer, main scene, Web export preset, threads, GDExtension,
PWA output, adaptive canvas resizing, initial focus, entry filename, and mobile texture compression.
Blocking issues prevent a supported release; recommendations remain visible when a choice depends on
the project. Safe fixes never enable mobile texture compression automatically because its size and
quality tradeoff must be tested by the creator.

After export, the addon copies the project's root `prototir.json` beside `index.html`. If no source
manifest exists, it generates valid defaults from the project name and exact Godot version.

Run the structural validator outside Godot with:

```bash
node tools/export-validator.mjs /path/to/export
```

## Web bridge and local behavior

The Prototir sandbox supplies a CSP-safe JavaScript interface. The addon retrieves that interface
with `JavaScriptBridge.get_interface()` and never executes inline JavaScript or requests
`unsafe-eval`. Editor and native play mode use in-memory storage and mock signals; managed AI
requires an explicit `mock_ai_handler`.

## Documentation and examples

- [Addon quick reference](addons/prototir/README.md)
- [Godot examples](https://github.com/prototir/godot-examples)
- [Creator documentation](https://prototir.com/docs/creators?runtime=godot#setup)
- [Release process](DISTRIBUTION.md)

## Validate the addon

```bash
node tools/test.mjs
```

A tagged release must additionally open without script errors in Godot 4.3+, produce a release Web
export, pass the structural validator, and play in the real Prototir sandbox.

## License

[MIT](LICENSE.md)
