import { spawnSync } from "node:child_process";
import { stripVTControlCharacters } from "node:util";

// Godot can report a script compilation/runtime error and still exit zero. Keep that from
// turning a broken import, test harness, or smoke scene into a green CI job.
const result = spawnSync(
  process.env.GODOT_BIN ?? "godot",
  process.argv.slice(2),
  {
    encoding: "utf8",
    timeout: 120_000,
    maxBuffer: 8 * 1024 * 1024,
  },
);
process.stdout.write(result.stdout ?? "");
process.stderr.write(result.stderr ?? "");
if (result.error) console.error(result.error.message);
const output = stripVTControlCharacters(
  (result.stdout ?? "") + "\n" + (result.stderr ?? ""),
);
const errors = /^(?:SCRIPT ERROR|ERROR):/m.test(output);
process.exitCode = result.error || result.status !== 0 || errors ? 1 : 0;
