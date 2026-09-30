# Prototir SDK for Godot

The official Godot integration for prototypes hosted on [Prototir](https://prototir.com). The addon
connects browser and native exports to lifecycle signals, analytics events, scores, and feedback.
Browser exports also use persistent SDK storage, managed text generation, and screenshot feedback.
Native releases pair with a tester's account and report over HTTP. The editor dock checks browser
export settings so unsupported profiles are caught before upload.

## Compatibility

- Godot 4.3 or newer
- GDScript integration
- Browser: Compatibility renderer, single-threaded Web export using the standard runtime profile
- Native: Windows, macOS, and Linux release exports, with device pairing

## Install

Download the `addons/prototir` directory from the
[v0.3.0 release](https://github.com/prototir/godot-sdk/releases/tag/v0.3.0) and copy it into your
project. Then:

1. Enable **Prototir SDK** under **Project Settings > Plugins**.
2. Open the **Prototir** dock.
3. For browser exports, apply safe fixes and resolve every browser-profile blocking item.
4. Use the appropriate **Export for Prototir** command for a browser or native release.
   Native builds do not need `index.html`; see [Native builds](#native-builds).

The addon installs `Prototir` as an autoload. Pin a published release tag for reproducible projects.

## Basic use

Browser exports use the host connection. Native releases must pair before sending sessions or
text feedback; see [Native builds](#native-builds). Storage and AI in this example
are browser features; native calls use local mocks.

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

The dock starts with **Building for: Web | Native**. The choice is saved per project in the
editor's project metadata, and until you pick it follows your export presets.

- **Every build:** Godot version and main scene.
- **Web:** Compatibility renderer, Web export preset, threads, GDExtension, PWA output, adaptive
  canvas resizing, initial focus, entry filename, and mobile texture compression.
- **Native:** an export preset for the machine you are on. None of the Web rules apply.

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
`unsafe-eval`. The Editor emits mock signals and can test pairing, but never reports development
play as a real session. Native releases report Ready, events, scores, sessions, and text feedback
after pairing. SDK storage remains in memory outside Web exports, and managed AI requires an
explicit local `mock_ai_handler`; use your own save files for persistent native state.

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

Off Prototir the mark opens an icon menu with **Screenshot** and **Review files** while offline,
or **Screenshot** and **Comments** when connected to Prototir. **Open on Prototir** appears when
configured. Choosing Screenshot captures the frame and opens the focused composer; Review files
contains import and export.

Connect `review_visibility_changed` and pause while the panel is open, otherwise the game keeps
consuming the input the tester is typing into their comment.

Screenshots come from the viewport after `RenderingServer.frame_post_draw`, so they match the
rendered frame. The export plugin bundles the browser runtime with the export, which is what lets
this work off Prototir; re-export with the addon enabled after upgrading.

For browser exports hosted elsewhere, `review_enable` accepts `api_base` and `slug` for the
browser panel's connection. Without that connection, the browser panel saves review files offline.

`review_enable` warns and returns on non-Web exports. On Prototir the feedback becomes an ordinary
comment on the prototype, after Prototir's own confirmation dialog. In a Web export you host
yourself the panel saves a `feedback.prototir-review.json` file that the tester sends you and you
reload with **Import review**. See the
[Web SDK README](https://github.com/prototir/web-sdk#screenshot-feedback) for the file format and its
limits.

### Text feedback from a native build

A native export pairs through a code approved at `prototir.com/link`, receiving authorization for
one prototype. After approval, call `Prototir.send_feedback(text)` from your own comment UI.
The browser `review_enable` screenshot overlay does not run in a native export.

The addon reuses the pairing until it is revoked or expires. Keep the tester's draft on send failure
and offer a retry. Testers can disconnect a build from their Prototir account settings.

## Native builds

A Web export takes everything from the page around it: the visitor is already signed in, and the
shell watches the prototype and reports for it. A native build has none of that, so the addon does it
itself.

You do not configure the slug. Prototir writes it into the .zip as you upload the build, into a
`prototir-prototype.json` beside the executable, and the addon reads it from there. The slug does
not exist until the prototype does, so there was never a value you could have put in your first
export.

Override it in **Project Settings > Prototir > Prototype Slug** when you need to: a build you ship
outside Prototir, or an installer Prototir cannot write into. Call `Prototir.configure("your-slug")`
if your game decides it at runtime. The injected slug wins over the project setting, because it
travelled with that exact download. Then:

Since `v0.2.1` the addon includes a built-in pairing screen:

```gdscript
func _ready() -> void:
    Prototir.ready()
    if not Prototir.is_paired():
        Prototir.show_pairing_screen()
```

It draws the code large, rasterises the QR, offers **Open in browser** and **Copy code**, and
closes itself once the tester approves. Use it as it is, restyle it, or ignore it entirely.

**Drawing your own is still fully supported**, and is the right answer as soon as your game has a
look of its own. The addon hands you everything and takes no opinion:

```gdscript
func _ready() -> void:
    Prototir.pairing_started.connect(_show_code)
    if not Prototir.is_paired():
        await Prototir.begin_pairing()

func _show_code(request: Dictionary) -> void:
    # request.code, request.verification_url, request.qr_svg, request.prototype_title
    $Code.text = request.code
```

Give the tester a way to act on it. A game window has no selectable text, so a printed URL on its
own leaves them retyping it off a screen: offer `OS.shell_open(request.verification_url)` on
desktop, and `DisplayServer.clipboard_set(request.code)` or the QR where a browser on this machine
helps nobody, such as a headset. `request.qr_svg` is SVG text, which
`Image.load_svg_from_string()` turns into a texture.

`examples/pairing/` builds the same flow with unstyled controls, if you would rather start from
something plain than restyle the shipped screen.

`ready()`, `event()` and `score()` accumulate one session rather than one request each, and the
addon reports it for you every 30 seconds while the game runs, and again when the window loses
focus. You do not have to call anything. `Prototir.flush_session()` is there for a natural break,
such as the end of a run, if you want the numbers to land sooner.

Repeating costs nothing: the first report returns an id the rest carry, so the server updates one
row rather than counting a play per report. When the window closes there is no time left to send,
so whatever the last report missed is written to `user://prototir/pending` and goes out the next
time the build starts. That covers the tester playing on a train as well. `Prototir.send_feedback("...")` posts a comment as the tester who approved the
build; no session is needed first, because approving the pairing is the stronger signal.

Pairing works when you run from the editor, so you can build the screen without exporting every
time. Reporting does not: an F5 run is not a play, and counting it would put your own testing in
your own numbers.

Nothing here reaches a Web export. **Prototir > Export for Prototir (Web)** adds
`addons/prototir/native/*` to that preset's exclude filter, and the Native button excludes
`addons/prototir/web/*`, so each build carries only the transport it can use. You can see and change
both in **Project > Export > Resources > Exclude**.

## Export buttons

Two entries under **Project > Tools**:

- **Prototir: Export for Prototir (Web)** runs the Web preflight, exports, and zips the result.
- **Prototir: Export for Prototir (Native)** exports for the machine you are on.

Both produce a ZIP ready to drop on the upload page, and both write `prototir-build.json` beside the
build. Prototir records that id from the archive, and a running build reports the same id when it
pairs; a match shows the build running is the build that was uploaded, and nothing more. Both sides
come from a file you control, so it is not verification, security or anti-cheat. It catches an old
build being run against a new upload.

Exporting for the other desktop platforms needs their export templates, so those stay in the normal
Export dialog rather than behind a button that would produce a build nobody can run.

## Publish to Prototir

**Prototir: Publish to Prototir (Web)** and **(Native)**, also under **Project > Tools**, export,
upload, and open your browser with the build waiting for you. You finish the details there and
publish; the editor never publishes on its own.

- **First time on a computer:** the editor asks to be linked to your account. Your browser opens
  an approval page with a code; approve it once and every project on this machine can publish.
  The link can only upload builds. See or remove it under **Linked editors** on your account page,
  or use **Prototir: Unlink This Editor**.
- **Project with a slug** (Project Settings > `prototir/prototype_slug`): the browser opens that
  prototype's Studio page instead, to replace its web build or add this native build.
- **Uploads wait for you** for 7 days, listed on the upload page (new prototype) or in Studio
  (project with a slug), so closing or reloading the browser loses nothing. A newer upload for the
  same prototype and platform replaces the older one.
- **Version:** a native build is offered with Project Settings > Application > Config > Version,
  which you can change on the website. Its architecture comes from the export preset
  (`binary_format/architecture`).
- **Automated builds** keep using Export for Prototir: Publish needs a person at a browser.

## Documentation and examples

- [Addon quick reference](addons/prototir/README.md)
- [Godot examples](https://github.com/prototir/godot-examples)
- [Creator documentation](https://prototir.com/docs/creators?runtime=godot#setup)
- [Release process](DISTRIBUTION.md)

## Validate the addon

```bash
node tools/test.mjs
node tools/test-godot-runner.mjs
node tools/run-godot.mjs --headless --path . --import
node tools/run-godot.mjs --headless --path . tests/validate_scripts.tscn --quit-after 600
node tools/run-godot.mjs --headless --path . tests/run_tests.tscn --quit-after 600
```

The first checks structure. The project scenes validate every script with the `Prototir` autoload
available, then run the pairing flow, session recorder, and built-in pairing UI against fake HTTP,
a fake clock, and fake signals. Nothing requests a real pairing code. Set `GODOT_BIN` to the engine
executable if it is not on PATH. The runner fails on script errors even if Godot exits zero.

A tagged release must additionally open without script errors in Godot 4.3+, produce a release Web
export, pass the structural validator, and play in the real Prototir sandbox.

## License

[MIT](LICENSE.md)

### Simple native feedback

Call `Prototir.show_feedback_screen()` from your game's Feedback button. The desktop screen retains unfinished comments during this run and failed posts, and offers browser pairing when needed. After pairing the tester reviews the draft and presses Post. A retry reuses the submission ID, and comments pass the existing API text checks. The returned screen emits `closed` for custom pause handling.

These flat overlays are not headset UI. VR projects should use their own interface and the pairing signals / `send_feedback`. Native screenshots are not provided.
