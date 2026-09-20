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

## Screenshot feedback

Call `review_enable` to give testers a floating feedback button in Web exports. They capture the
current view, drop a pin on that screenshot and write a comment.

```gdscript
func _ready() -> void:
	Prototir.review_visibility_changed.connect(_on_review_visibility)
	Prototir.review_enable("orbit-garden", "v1.4.0", "bottom-left")


func _on_review_visibility(open: bool) -> void:
	get_tree().paused = open
```

`review_enable(project, build, corner, launcher, theme)` takes a stable `project` identifier (reviews exported from
another project are refused on import), a `build` recorded with the feedback, and a corner of
`bottom-left` (default), `bottom-right`, `top-left`, or `top-right`. `review_disable()` removes the
overlay. `launcher` is `auto` (Prototir draws the control on its own surfaces), `watermark` (always
show the Prototir mark and its menu) or `host` (draw nothing). `theme` is `auto`, `light` or `dark`.

Off Prototir the mark opens the same menu testers see in a web build - **Screenshot & comment**,
**Comments**, **Open on Prototir** - so the experience does not change between web and native.

Connect `review_visibility_changed` and pause while the panel is open, otherwise the game keeps
consuming the input the tester is typing into their comment.

Screenshots come from the viewport after `RenderingServer.frame_post_draw`, so they match the
rendered frame. The export plugin bundles the browser runtime with the export, which is what lets
this work off Prototir; re-export with the addon enabled after upgrading.

### Posting from a downloaded build

A native export has no Prototir session, and providers like Google refuse to sign in inside an
embedded browser. So the export sends the tester to a real one: it shows a short code and a QR, the
tester approves at `prototir.com/link` on their desktop or phone, and the build receives a token
scoped to that one prototype.

They approve once per machine, not once per comment, and the screenshot they were writing is kept
and posted the moment they come back. Testers can disconnect any build from their Prototir account
settings.

Pass `api_base` and `slug` to enable it. Without them the panel saves review files instead, which
needs no account and works offline.

`review_enable` warns and returns on non-Web exports. On Prototir the feedback becomes an ordinary
comment on the prototype, after Prototir's own confirmation dialog. In a Web export you host
yourself the panel saves a `feedback.prototir-review.json` file that the tester sends you and you
reload with **Import review**. See the
[Web SDK README](https://github.com/prototir/web-sdk#screenshot-feedback) for the file format and its
limits.

## Downloadable builds

A Web export takes everything from the page around it: the visitor is already signed in, and the
shell watches the prototype and reports for it. A download has none of that, so the addon does it
itself.

Set the slug in **Project Settings > Prototir > Prototype Slug**, or call
`Prototir.configure("your-slug")` if your game decides it at runtime. Then:

```gdscript
func _ready() -> void:
    Prototir.ready()
    Prototir.pairing_started.connect(_show_code)
    if not Prototir.is_paired():
        await Prototir.begin_pairing()

func _show_code(request: Dictionary) -> void:
    # request.code, request.verification_url, request.qr_svg, request.prototype_title
    $Code.text = request.code
```

The addon draws nothing. It cannot know your art direction, your input model, or whether you are in
VR, so it hands you the code, the link and a ready-made QR and leaves the screen to you.

Give the tester a way to act on it. A game window has no selectable text, so a printed URL on its
own leaves them retyping it off a screen: offer `OS.shell_open(request.verification_url)` on
desktop, and `DisplayServer.clipboard_set(request.code)` or the QR where a browser on this machine
helps nobody, such as a headset.

`examples/pairing/` is a working version of all of that in one script, building its own UI in code
so it drops into any scene without wiring. Run it, then rebuild it in whatever UI your game already
uses.

`ready()`, `event()` and `score()` accumulate one session rather than one request each. Call
`Prototir.flush_session()` at a natural break, such as the end of a run. When the window closes
there is no time to send anything, so the session is written to `user://prototir/pending` instead
and sent the next time the build starts. That covers the tester playing on a train as well: sessions
carry their server id, so one arriving late updates its row rather than counting a second play. `Prototir.send_feedback("...")` posts a comment as the tester who approved the
build; no session is needed first, because approving the pairing is the stronger signal.

Pairing works when you run from the editor, so you can build the screen without exporting every
time. Reporting does not: an F5 run is not a play, and counting it would put your own testing in
your own numbers.

Nothing here reaches a Web export. **Prototir > Export for Prototir (Web)** adds
`addons/prototir/native/*` to that preset's exclude filter, and the Download button excludes
`addons/prototir/web/*`, so each build carries only the transport it can use. You can see and change
both in **Project > Export > Resources > Exclude**.

## Export buttons

Two entries under **Project > Tools**:

- **Prototir: Export for Prototir (Web)** runs the Web preflight, exports, and zips the result.
- **Prototir: Export for Prototir (Download)** exports for the machine you are on.

Both produce a ZIP ready to drop on the upload page, and both write `prototir-build.json` beside the
build. Prototir records that id from the archive, and a running build reports the same id when it
pairs; a match shows the build running is the build that was uploaded, and nothing more. Both sides
come from a file you control, so it is not verification, security or anti-cheat. It catches an old
build being run against a new upload.

Exporting for the other desktop platforms needs their export templates, so those stay in the normal
Export dialog rather than behind a button that would produce a build nobody can run.

## Documentation and examples

- [Addon quick reference](addons/prototir/README.md)
- [Godot examples](https://github.com/prototir/godot-examples)
- [Creator documentation](https://prototir.com/docs/creators?runtime=godot#setup)
- [Release process](DISTRIBUTION.md)

## Validate the addon

```bash
node tools/test.mjs
godot --headless --path . --script tests/run_tests.gd
```

The first checks structure. The second runs the pairing flow and the session recorder against fake
HTTP, a fake clock and a fake delay, so a poll loop that waits ten minutes for a deadline finishes
instantly and nothing touches the network.

A tagged release must additionally open without script errors in Godot 4.3+, produce a release Web
export, pass the structural validator, and play in the real Prototir sandbox.

## License

[MIT](LICENSE.md)
