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

## Done in v0.5
- Faster rescans: 42 s → 1.1 s on the author's Mac. The slow part was measuring ~/.cocoapods/repos
  (818k files). Sizes of unchanged folders are reused for up to 24 h; Rescan Fully re-measures everything.
- Docker recipe through `docker system df` and `docker ... prune`. Not tried against a real Docker yet
  (none on the author's Mac); parsing is unit tested.
- Dropped "compact Cursor's chat database": measured, a VACUUM would free about 1 MB of 11.5 GB.
  The data is real (agent state 6.8 GB, messages 1.7 GB). The app now says so and points to deleting
  old chats in Cursor instead.
- Glass fallback for macOS 14/15 (thin material, lit rim, soft shadow). Real Liquid Glass needs macOS 26.

## Done in v0.6
- Agent worktrees recipe (Cursor, Claude Code, Codex, any registered git worktree), removed only through
  `git worktree remove` without --force. Protected: uncommitted or untracked files, commits on no branch,
  locked, used in the last 7 days, or open in a running process.
- Safe clean no longer fails on the Dart analysis cache; the scanner runs the cleaner's path check up front.
- History records why each item was skipped.

## Done in v0.7
- **Large files** section (sidebar, under "Your files"): the user's own files over 100 MB outside developer
  folders, found through Spotlight (fallback: Downloads, Desktop, Documents, Movies, Music, Pictures).
  Filters by type, size (100 MB to 1 GB) and "not opened longest". Nothing is pre-selected, everything is
  Has data, removal is always Trash (the Cleaner forces it), and it is outside safe clean, the menu bar,
  rules, MCP and the CLI clean. Skipped: ~/Library, hidden folders, git repositories, sync folders
  (Dropbox, OneDrive, Google Drive), packages (.app, .photoslibrary), unfinished downloads.

## Next
See `docs/NOTES.md` for the current status, decisions and the ordered to-do list.
- **P1 · Stable local signing** so macOS stops asking for folder access after every build.
- **P2 · Verify Docker** on a Mac that has it, and the glass look on macOS 26.

## v1.0
- **P1** Developer ID signing, notarization, DMG, Homebrew cask, Sparkle updates.
- **P1** Turkish and English UI.
- **P2** Community recipes as data files, landing page.
