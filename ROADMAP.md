# Roadmap

Priorities: **P0** blocks real use, **P1** needed before publishing, **P2** nice to have.

## Done
- **v0.1** Scanner, 11 recipes, safety checks, app (overview, area detail, review sheet), CLI.
- **v0.2** Menu bar popover with one-click safe clean, low-disk notifications, settings.

## v0.3 (in progress)
- **P0 · AI tools & editors.** Cursor, Claude, VS Code, Windsurf caches and state, old Claude Code
  versions, Claude VM bundles, Ollama models, Dart analysis server cache. On the author's Mac this is the
  largest group (about 38 GB), and no other cleaner understands it. App data is protected while the app runs.
- **P0 · Scan progress.** A 45 s scan needs more than a spinner: a determinate bar over the scan steps,
  a live checklist of areas with what each found, and a running total.
- **P1 · Liquid Glass.** Built with the macOS 26 SDK: glass on the control layer (floating selection
  bar, primary buttons, popover actions), never on content. Material fallback on macOS 14 and 15.
- **P1 · Logo and app icon.**

## v0.4
- **P1 · MCP server**: `disk_status`, `plan_cleanup`, `clean_safe` (Rebuilds tier only).
- **P1 · Automation rules**: weekly sweep of stale projects, auto-clean Rebuilds below a threshold.
- **P2 · Faster scans**: cache project discovery and sizes, rescan only what changed.
- **P2 · Compact Cursor's chat database** (SQLite VACUUM) instead of deleting it.
- **P2 · Start hidden at login** (menu bar only).

## v1.0
- **P1** Developer ID signing, notarization, DMG, Homebrew cask, Sparkle updates.
- **P1** Turkish and English UI.
- **P2** Community recipes as data files, landing page.
