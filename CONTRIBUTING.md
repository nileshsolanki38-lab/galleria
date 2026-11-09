# Contributing to Galleria

Thanks for your interest! Galleria is a small, dependency-free Swift + SwiftUI app.

## Prerequisites

- macOS 14+ (Sonoma or later)
- Xcode Command Line Tools (`xcode-select --install`)
- No full Xcode required — the build script uses the Command Line Tools SDK.

## Build

```bash
git clone https://github.com/nileshsolanki38-lab/galleria.git
cd galleria
./Scripts/build.sh
open dist/Galleria.app
```

The script builds against the macOS 26 SDK on purpose: the macOS 27 SDK turns
SwiftUI's `@State` into a macro whose plugin only ships with full Xcode.

## Running tests

There is no XCTest suite yet. Smoke-test the app manually:

1. Launch `dist/Galleria.app`.
2. **Add Folder…** (⇧⌘O) → point at a folder with photos.
3. Open a photo (double-click or Return), try zoom/pan, filmstrip, edits, export (⌘E).
4. Collage Maker (⇧⌘C), Compare, Faces, Places, Smart Albums, Duplicates, Batch.

Engine-level checks live in `/tmp/TestHarness.swift` (not in the repo). If you add
tests, please put them under a `Tests/` directory and wire them into CI.

## Code style

- Match the surrounding style (4-space indent, MARK comments, SwiftUI).
- Keep the non-destructive edit model: edits are JSON recipes in SQLite, never
  mutate the original file.
- Imaging filters: only use Core Image filters that exist on macOS 14+. Invalid
  KVC keys throw `NSUnknownKeyException` and abort the process — verify filter
  names and keys before merging.

## Pull requests

- One feature/fix per PR.
- Describe what you changed and how you tested it.
- Run `./Scripts/build.sh` and confirm it succeeds before submitting.

## Reporting bugs

Please include: macOS version, Galleria version, steps to reproduce, and (if
possible) a sample image. File issues at
https://github.com/nileshsolanki38-lab/galleria/issues.
