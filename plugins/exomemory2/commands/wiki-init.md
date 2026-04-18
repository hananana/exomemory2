---
description: Create a new external memory vault at the given path
argument-hint: <vault-path>
allowed-tools: Bash(cp:*), Bash(mkdir:*), Bash(test:*), Bash(ls:*)
---

# /wiki-init

Initialize a new external memory vault at `$1`.

## Steps

### 1. Validate target path

Run the following to ensure the target does not already exist as a non-empty directory:

!`test -e "$1" && echo "EXISTS" || echo "OK"`

- If output is `EXISTS`:
  - Check if the directory is empty: !`ls -A "$1" 2>/dev/null | head -1`
  - If non-empty, **stop** and report: `"Target already exists and is not empty: $1. Choose a different path or remove the existing directory first."`
  - If empty, proceed to step 2 (treating it as a fresh target)

### 2. Copy template

Copy the plugin's template skeleton to the vault path. Use `${CLAUDE_PLUGIN_ROOT}` to locate template files portably:

!`mkdir -p "$1" && cp -R ${CLAUDE_PLUGIN_ROOT}/template/. "$1"/`

### 3. Verify structure

Check that the vault was created correctly:

!`ls -la "$1" && ls -la "$1"/wiki && ls -la "$1"/raw`

Expected to see `WIKI.md`, `raw/` directory (with `handovers/` inside), and `wiki/` directory containing `index.md`, `log.md`, `overview.md`, `sources/`, `entities/`, `concepts/`.

### 4. Report to user

After successful creation, tell the user:

```
Vault created at: <absolute path of $1>

Next steps:
  1. Set environment variable: export CLAUDE_MEMORY_VAULT="<absolute path>"
     (add this to ~/.zshrc or ~/.bashrc to make it persistent)
  2. Drop source documents into: <path>/raw/
  3. Ingest them with: /wiki-ingest <path>/raw/<filename>
  4. Query the wiki with: /wiki-query "your question"

Automatic capture of Claude conversations will start working once
$CLAUDE_MEMORY_VAULT is set. PreCompact and SessionEnd hooks will
write handover files to <path>/raw/handovers/<session-id>.md.
```

## Notes

- If `$1` is not provided, report usage: `/wiki-init <vault-path>` and stop.
- The target path can be absolute or relative to the current working directory.
- Do not attempt to create nested directories beyond what `cp -R` already handles.
