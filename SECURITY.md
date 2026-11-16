# Security

DevSweep deletes files, so a bug that removes the wrong path is treated as a security issue.

## Reporting

Please report security problems privately through GitHub:
**Security > Report a vulnerability** on this repository. Do not open a public issue.

Useful details: the DevSweep version, macOS version, the item or path involved, and the
relevant lines from `~/Library/Application Support/DevSweep/history.jsonl`.

## Scope

- A path removed that is outside the documented safety model (see README, "Safety model").
- A protected item (running simulator, active project, in-use version, "Always keep") being removed.
- The MCP server cleaning anything beyond Rebuilds items, or cleaning while agent cleaning is off.
