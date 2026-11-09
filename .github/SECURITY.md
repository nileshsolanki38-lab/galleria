# Security Policy

## Scope

Galleria is a **macOS desktop app** that works entirely offline:

- No network connections, no analytics, no telemetry, no accounts.
- All data stays on your Mac: the catalogue in
  `~/Library/Application Support/Galleria/library.sqlite` and thumbnails in
  `~/Library/Caches/Galleria/Thumbs`.
- Edits are stored as JSON recipes in the catalogue; **your original image files are never modified**.

## Reporting a vulnerability

Please report suspected vulnerabilities privately via
[GitHub Security Advisories](https://github.com/nileshsolanki38-lab/galleria/security/advisories/new)
("Report a vulnerability" button) rather than a public issue. Include the Galleria version and steps
to reproduce. You can expect a reply within a few days.

## Verifying a download

Every [release](https://github.com/nileshsolanki38-lab/galleria/releases/latest) ships
`Galleria.dmg` plus a `.sha256` checksum:

```bash
shasum -a 256 Galleria.dmg
# compare with Galleria.dmg.sha256
```

## Data locations

| What | Where | Deleting it |
|---|---|---|
| Library catalogue (SQLite) | `~/Library/Application Support/Galleria/library.sqlite` | forgets folders, edits & tags (files untouched) |
| Thumbnail cache | `~/Library/Caches/Galleria/Thumbs` | regenerates automatically |
| Collage / edit exports | `~/Pictures/Galleria Exports` | normal user files |
