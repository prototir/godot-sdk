import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateGodotExport } from "./export-validator.mjs";

const root = mkdtempSync(join(tmpdir(), "prototir-godot-"));
try {
  writeFileSync(join(root, "index.html"), '<canvas id="canvas"></canvas>');
  writeFileSync(join(root, "game.wasm"), "fixture");
  writeFileSync(join(root, "game.pck"), "fixture");
  writeFileSync(
    join(root, "prototir.json"),
    JSON.stringify({ runtime: { engine: "godot", profile: "standard" } }),
  );
  assert.deepEqual(validateGodotExport(root), []);
  writeFileSync(join(root, "game.js.map"), "fixture");
  assert.match(validateGodotExport(root).join("\n"), /Source maps/);

  const addon = readFileSync(
    new URL("../addons/prototir/prototir.gd", import.meta.url),
    "utf8",
  );
  for (const token of [
    "PROTOCOL_VERSION := 1",
    "func ready()",
    "func event(",
    "func score(",
    "func storage_get(",
    "func ai_generate(",
  ])
    assert.ok(addon.includes(token), `addon missing ${token}`);
  assert.ok(
    addon.includes('JavaScriptBridge.get_interface("__prototirGodotBridge")'),
  );
  assert.ok(
    !addon.includes('JavaScriptBridge.eval("""'),
    "addon must remain compatible with CSP without unsafe-eval",
  );

  const plugin = readFileSync(
    new URL("../addons/prototir/plugin.cfg", import.meta.url),
    "utf8",
  );
  assert.match(plugin, /version="0\.1\.0"/);
  const sampleScene = readFileSync(
    new URL("../examples/basic/main.tscn", import.meta.url),
    "utf8",
  );
  assert.match(sampleScene, /res:\/\/examples\/basic\/main\.gd/);
  assert.ok(
    existsSync(new URL("../examples/basic/main.gd", import.meta.url)),
    "sample scene script is missing",
  );
  const setup = readFileSync(
    new URL("../addons/prototir/setup.gd", import.meta.url),
    "utf8",
  );
  for (const token of [
    "func get_issues()",
    "variant/thread_support",
    "variant/extensions_support",
    "progressive_web_app/enabled",
    "html/canvas_resize_policy",
  ])
    assert.ok(setup.includes(token), `setup assistant missing ${token}`);
  const editorPlugin = readFileSync(
    new URL("../addons/prototir/plugin.gd", import.meta.url),
    "utf8",
  );
  for (const token of [
    "add_control_to_dock",
    "add_export_plugin",
    "Prototir: Validate Web Setup",
  ])
    assert.ok(editorPlugin.includes(token), `editor plugin missing ${token}`);
  const exportGuard = readFileSync(
    new URL("../addons/prototir/export_guard.gd", import.meta.url),
    "utf8",
  );
  for (const token of [
    "func _export_begin(",
    "func _export_end()",
    "prototir.json",
    "debug Web exports",
    '"name":',
    '"engineVersion":',
  ])
    assert.ok(exportGuard.includes(token), `export guard missing ${token}`);

  // The build id sidecar is read by Prototir and sits beside the Unity one, which writes a real
  // ISO 8601 instant. Godot's helper defaults to a space separator, which is neither ISO nor what
  // the other SDK produces, and the difference is invisible until someone parses the field.
  assert.ok(
    !/get_datetime_string_from_system\(true,\s*true\)/.test(exportGuard),
    'the build id timestamp must not use the space separator; pass use_space: false'
  );

  // What keeps a Web bundle free of the pairing client, and a download free of the browser
  // bridge. Behaviour is covered by tests/run_tests.gd; these two invariants are the ones that
  // break the stripping itself, and neither is visible from inside a running game.
  for (const token of ["Prototir: Export for Prototir (Web)", "Prototir: Export for Prototir (Download)"])
    assert.ok(editorPlugin.includes(token), `editor plugin missing ${token}`);
  const exportMenu = readFileSync(
    new URL("../addons/prototir/export_menu.gd", import.meta.url),
    "utf8",
  );
  assert.match(exportMenu, /WEB_EXCLUDES := "addons\/prototir\/native\/\*"/);
  assert.match(exportMenu, /DOWNLOAD_EXCLUDES := "addons\/prototir\/web\/\*"/);

  const autoload = readFileSync(
    new URL("../addons/prototir/prototir.gd", import.meta.url),
    "utf8",
  );
  assert.ok(
    !/preload\(\s*"res:\/\/addons\/prototir\/native\//.test(autoload),
    "the autoload must load() the native runtime, not preload() it: a preload keeps a hard " +
      "dependency on files the Web export strips, and the bundle then fails to open",
  );
  for (const name of ["native_runtime", "pairing_flow", "session_recorder", "native_transport", "session_queue"]) {
    const source = readFileSync(
      new URL(`../addons/prototir/native/${name}.gd`, import.meta.url),
      "utf8",
    );
    assert.ok(
      !/^class_name /m.test(source),
      `${name}.gd must not declare class_name: a script in the global class list that the Web ` +
        "export strips fails to resolve when the project loads",
    );
  }

  // Where a downloadable build talks to Prototir. It is written in two files and it is compiled
  // into executables that can never be updated, so drift between them, or a slip back to a host
  // that serves no /api, is not something to discover from a creator's bug report.
  const nativeRuntime = readFileSync(
    new URL("../addons/prototir/native/native_runtime.gd", import.meta.url),
    "utf8",
  );
  const defaultBase = /DEFAULT_API_BASE := "([^"]+)"/.exec(nativeRuntime)?.[1];
  const settingBase = /"prototir\/api_base_url": "([^"]+)"/.exec(editorPlugin)?.[1];
  assert.ok(defaultBase, "native_runtime.gd has no DEFAULT_API_BASE");
  assert.equal(
    settingBase,
    defaultBase,
    "the project-setting default and DEFAULT_API_BASE must name the same endpoint",
  );
  assert.ok(
    !/^https:\/\/prototir\.com\//.test(defaultBase),
    "prototir.com serves no /api path; the API has its own hostname",
  );
  assert.ok(
    !/azurewebsites\.net/.test(defaultBase),
    "the generated Azure hostname changes if the app is recreated, and this URL ships inside " +
      "executables that cannot be updated",
  );

  console.log("Godot addon and protocol checks passed.");
} finally {
  rmSync(root, { recursive: true, force: true });
}
