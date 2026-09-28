import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const runner = fileURLToPath(new URL("./run-godot.mjs", import.meta.url));
const cases = [
  ["clean run", "console.log('128 checks, 0 failed')", 0],
  ["nonfatal warning", "console.error('WARNING: setup recommendation')", 0],
  [
    "script error with zero exit",
    "console.error('SCRIPT ERROR: Compile Error: Identifier not found: Prototir')",
    1,
  ],
  [
    "engine error with zero exit",
    "console.error('ERROR: Failed to load script')",
    1,
  ],
  ["error on stdout", "console.log('SCRIPT ERROR: Runtime failure')", 1],
  [
    "colored error",
    "console.error('\u001b[31mSCRIPT ERROR: Compile Error\u001b[0m')",
    1,
  ],
  ["failed process", "process.exit(7)", 1],
];
for (const [name, source, expected] of cases) {
  // Use Node as a controlled child engine: no Godot installation is needed for this gate.
  const result = spawnSync(
    process.execPath,
    [runner, "--input-type=module", "-e", source],
    {
      env: { ...process.env, GODOT_BIN: process.execPath },
      encoding: "utf8",
    },
  );
  assert.equal(
    result.status,
    expected,
    `${name}: ${result.stdout}${result.stderr}`,
  );
}
console.log(`${cases.length} Godot runner failure-detection checks passed.`);
