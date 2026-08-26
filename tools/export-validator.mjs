import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';

export function validateGodotExport(root) {
  const errors = [];
  if (!existsSync(root)) return [`Export folder does not exist: ${root}`];
  const files = walk(root).map((file) => relative(root, file).replaceAll('\\', '/'));
  if (!files.includes('index.html')) errors.push('index.html must exist at the ZIP root.');
  if (!files.some((file) => file.toLowerCase().endsWith('.wasm')))
    errors.push('A Godot .wasm engine payload is required.');
  if (!files.some((file) => file.toLowerCase().endsWith('.pck')))
    errors.push('A Godot .pck project payload is required.');
  if (files.some((file) => file.toLowerCase().endsWith('service-worker.js')))
    errors.push('PWA/service-worker output is outside the standard profile.');
  if (files.some((file) => file.toLowerCase().endsWith('.map')))
    errors.push('Source maps/debug symbols are not accepted.');

  const manifestPath = join(root, 'prototir.json');
  if (existsSync(manifestPath)) {
    try {
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
      if (manifest.runtime?.engine !== 'godot') errors.push('prototir.json runtime.engine must be godot.');
      if (manifest.runtime?.profile && manifest.runtime.profile !== 'standard')
        errors.push('Only the standard runtime profile is currently supported.');
    } catch {
      errors.push('prototir.json must contain valid JSON.');
    }
  }
  return errors;
}
function walk(root) {
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}

if (process.argv[1]?.endsWith('export-validator.mjs') && process.argv[2]) {
  const errors = validateGodotExport(process.argv[2]);
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exitCode = 1;
  } else {
    console.log('Godot Web export matches the Prototir standard profile.');
  }
}
