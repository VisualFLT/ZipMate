# ZipMate

Minimal 7-Zip UI for macOS.

ZipMate is a lightweight macOS UI and practical replacement for 7-Zip on Mac.
It keeps the 7-Zip engine, and focuses on the parts that matter on macOS:
browse, extract, drag, pack, and move fast.

## What It Is

- A Mac UI for `7zz`
- A simple archive browser
- A practical alternative to the usual compressed-file workflow on macOS
- Built for minimalism and direct use

## What It Does

- Open archives and browse them like a file manager
- Double-click folders to enter
- Single-click to select
- Extract selected items
- Extract everything
- Drag files out to extract
- Drag files in to pack
- Create empty archives
- Switch UI between Chinese and English
- Use bundled `7zz` or a custom path

## Supported Types

- `zip`
- `7z`
- `rar`
- `tar`

## Install

Open the `dmg`, then drag `ZipMate.app` into `Applications`.

On first launch, you can choose which archive types should open with ZipMate by default.

## Build

```bash
swift build
```

## Run

```bash
swift run
```

## Bundled Engine

ZipMate can use a bundled `7zz` binary.

Put `7zz` at:

```text
Sources/SevenZipMacUI/Resources/7zz
```

Keep `Prefer bundled 7zz` enabled in the app.

## Notes

- ZipMate is a UI and workflow layer on top of 7-Zip.
- The project aims to stay small, direct, and easy to use.
- Finder right-click integration on macOS is more limited than on Windows.
- Default file association is supported for the main archive types.

## License

This project uses the 7-Zip engine.
Please also review the upstream 7-Zip license terms and the `unRAR` restriction before redistribution.

