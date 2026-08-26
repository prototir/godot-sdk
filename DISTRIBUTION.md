# Releasing the Godot SDK

GitHub is the canonical source and release history. Each release uses the same semantic version in
`addons/prototir/plugin.cfg`, `CHANGELOG.md`, the Git tag, and the GitHub release.

## Release checklist

1. Run `node tools/test.mjs`.
2. Open the validation project in the oldest supported Godot release and fix script warnings.
3. Export a non-debug Web build and run `node tools/export-validator.mjs <export-folder>`.
4. Upload and play the export on Prototir with no blocking console or publication diagnostics.
5. Update `CHANGELOG.md`, commit, create the immutable `vX.Y.Z` tag, and publish a GitHub release.
6. Attach a ZIP containing `addons/prototir` and update documentation links after the tag exists.

The GitHub release is the canonical direct-download channel. A future Godot Asset Library listing
should point to the same immutable tagged commit and MIT-licensed addon instead of maintaining a
separate implementation branch.
