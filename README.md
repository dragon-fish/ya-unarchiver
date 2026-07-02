# YA Unarchiver for macOS

**YA Unarchiver** — 又一个 macOS 的解压软件.

> "YA" = *Yet Another* … and also **压** (*yā*), the Chinese for "compress". 😄

A native macOS (SwiftUI) archive **browser & extractor** that wraps the official
7-Zip (`7zz`) engine. It does the one thing most macOS tools miss: **browse an
archive's contents like Finder — without extracting it first.**

## Why

Keka is great but can't preview an archive's contents; other tools feel dated.
YA Unarchiver focuses on a clean, native, Finder-style *browse-then-extract*
experience.

## Features

- 🗂 **Finder-style two-pane browsing** — folder tree + file list (name / size /
  packed size / modified), no extraction needed.
- 📦 **Extract all or selected**, with a smart destination: a single top-level
  folder is released as-is (no `foo/foo` double-nesting); otherwise the contents
  are wrapped in a folder named after the archive. Name collisions prompt
  **Cancel / Delete-then-extract / Numbered** (`name 2`, `name 3`, …).
- 🔒 **Password-protected archives** — prompts for a password and re-prompts on a
  wrong one.
- 🖱 **Open via** Finder double-click (file association), drag-and-drop, ⌘O, or the
  welcome-screen button.
- 🎨 **Native look** — system semantic colors, automatic light/dark, one window
  per archive.
- 🚀 **Self-contained** — bundles the official `7zz`; no Homebrew needed at runtime.
- 🧩 **Broad format support** via 7-Zip: zip, 7z, rar, tar, gz, xz, bz2, tar.gz, …

## Requirements

- macOS 14 or later.
- To build: a Swift toolchain (Xcode or the Command Line Tools). Running the test
  suite needs the full **Xcode** toolchain — the Command Line Tools SDK lacks
  XCTest.

## Build & run

The `7zz` engine binary is **not** committed to this repository. Fetch it once,
then build:

```bash
make fetch-7zz   # download the official 7zz into Resources/  (or: ./scripts/fetch-7zz.sh)
make build       # assemble YAUnarchiver.app under .build/
make run         # build, then launch
make test        # run the unit tests
```

Run `make` with no target to list all commands. The build uses pure Swift Package
Manager — no Xcode project required.

## License

- This project's own code (the SwiftUI app and the `ArchiveKit` library) is
  licensed under the **Apache License 2.0** — see [LICENSE](LICENSE).
- The bundled **7-Zip** engine (`7zz`, downloaded at build time, **not** part of
  this repository) is a product of the 7-Zip project by Igor Pavlov and is under
  **its own license** (GNU LGPL + unRAR restriction) — see
  [LICENSE-7zip](LICENSE-7zip). It is **not** covered by this project's Apache 2.0
  license.

## Status & roadmap

v1 ships **browsing + extraction**. Planned next:

- Drag files out of an archive into Finder
- Creating / compressing archives (with an optional, default-on *exclude dotfiles* choice)
- Finder right-click extension

---

© 2026 dragon-fish · Not affiliated with the 7-Zip project.
