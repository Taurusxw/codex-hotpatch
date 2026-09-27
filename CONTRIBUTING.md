# Contributing

Keep this project focused on preparing official Codex Desktop runtime caches on Windows. Do not modify `app.asar`, session files, databases, proxy or provider configuration, or permanent environment variables. Do not restart Codex or remove existing official caches.

## Development

1. Make a focused change in `runtime-repair/` and preserve unrelated work.
2. Update the component version and README when behavior changes. The repository `VERSION` and existing release records describe the last published release until a new release is explicitly authorized.
3. Never commit credentials, `.env`, logs, runtime state, local handovers, installed copies, or recovery backups.
4. Keep the content-hash algorithm compatible with the official desktop resolver. Preserve matching files and publish only verified replacements.

## Validation

Run the following from the repository root under both Windows PowerShell 5.1 and PowerShell 7:

```powershell
& '.\runtime-repair\runtime-cache.tests.ps1'
& '.\runtime-repair\runtime-watchdog.tests.ps1'
& '.\runtime-repair\manage-hotpatch.tests.ps1'
```

Keep PowerShell sources in UTF-8 with BOM and CRLF for Windows PowerShell 5.1. Tests use isolated temporary fixtures, including a temporary watcher process; they do not restart Codex or change networking. Cache tests cover missing and corrupt siblings, file locks, content identities, full Node dependencies, and preserving old runtimes. Watchdog tests cover Stage selection, retries, and avoiding repeated idle work. Lifecycle tests cover exact process selection, fresh status, and stopping only the fixture.

For installation changes, also verify the installed guard and startup shortcut using Windows PowerShell 5.1, which hosts the Appx watcher. Confirm existing Codex processes and user configuration remain unchanged. A ready cache is not evidence that network streaming is healthy.

## Pull requests

Explain the concrete problem, resulting behavior, focused validation, and remaining compatibility limits. Historical release documentation remains historical; do not rewrite it to describe an unpublished working tree.
