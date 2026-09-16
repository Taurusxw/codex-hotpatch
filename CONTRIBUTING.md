# Contributing

Contributions should preserve the project's core boundary: user-level, reversible patches that do not modify or repackage `app.asar`, session JSONL, SQLite databases, or permanent Windows proxy settings.

## Development

1. Fork the repository and create a focused branch.
2. Keep compatibility changes minimal and avoid unrelated refactors.
3. Do not commit `.env`, logs, databases, local handovers, credentials, screenshots with private data, or installed runtime copies.
4. Update the affected component version and README when behavior changes.

## Validation

From the repository root, run:

```powershell
node --test `
  '.\subagent-status\completion-evidence.test.mjs' `
  '.\subagent-status\subagent-status-renderer.test.mjs' `
  '.\sidebar-archive-filter\archived-thread-index.test.mjs' `
  '.\sidebar-archive-filter\sidebar-archive-filter-renderer.test.mjs' `
  '.\shared\codex-devtools-transport.test.mjs'

& '.\network-proxy\manage-hotpatch.tests.ps1'
& '.\network-proxy\network-health.tests.ps1'
& '.\network-proxy\network-runtime-observer.tests.ps1'
& '.\network-proxy\install-rollback.tests.ps1'
& '.\network-proxy\launch-recovery.tests.ps1'
& '.\network-proxy\network-watchdog.tests.ps1'
& '.\network-proxy\runtime-cache.tests.ps1'
& '.\ui-hotpatch-supervisor\manage-hotpatch.tests.ps1'
```

Keep PowerShell sources in UTF-8 with BOM so Windows PowerShell 5.1 can parse Chinese strings. Run PowerShell checks under both Windows PowerShell 5.1 and PowerShell 7. The UI supervisor test starts and stops only a temporary fixture watcher; it does not restart Codex. Node tests include Windows short-path watcher coverage.

For user-visible UI changes, also verify the affected menu or panel in a running Codex instance. Network changes require targeted `Status`/`Doctor` evidence and must preserve the official compatibility fallback.

## Pull requests

Explain the reproduced problem, the smallest behavioral change, validation results, and remaining compatibility risk. Never include secrets or private runtime evidence in the pull request.
