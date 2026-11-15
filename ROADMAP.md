# Roadmap

Priorities: **P0** blocks real use, **P1** needed before publishing, **P2** nice to have.

## Done
- **v0.1** Scanner, 11 recipes, safety checks, app (overview, area detail, review sheet), CLI.
- **v0.2** Menu bar popover with one-click safe clean, low-disk notifications, settings.

## Done in v0.3
AI tools & editors area, scan progress screen, Liquid Glass control layer, logo and app icon.

## Done in v0.4
MCP server (`disk_status`, `plan_cleanup`, `clean_safe`), automation rules (off by default),
"Always keep" list, clean history, instant launch from the cached scan, start in the menu bar only.

## v0.5
- **P1 · Faster rescans**: only re-measure folders whose modification date changed.
- **P2 · Compact Cursor's chat database** (SQLite VACUUM, with a backup first) instead of deleting it.
- **P2 · Docker** (`docker system df`, prune unused images and build cache).

## v1.0
- **P1** Developer ID signing, notarization, DMG, Homebrew cask, Sparkle updates.
- **P1** Turkish and English UI.
- **P2** Community recipes as data files, landing page.
