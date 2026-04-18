---
description: Create a new external memory vault at the given path
argument-hint: <vault-path>
allowed-tools: Bash
---

# /wiki-init

Initialize a new external memory vault. Follow the steps below using the `Bash` tool. **Do not act until you have parsed and validated the argument.**

## Arguments

The user-supplied argument is:

```
$ARGUMENTS
```

## Step 1: Validate the argument

If `$ARGUMENTS` is empty or contains only whitespace, stop immediately and reply:

```
Usage: /wiki-init <vault-path>
Example: /wiki-init ~/vault-personal
```

Otherwise, take the **first whitespace-separated token** as the target vault path. Call it `VAULT_PATH` in your reasoning. Do not split on quotes; assume the user passes a single path.

## Step 2: Expand and validate the path

Use Bash to resolve `VAULT_PATH`:

```bash
# Expand ~ and get absolute path, but do not require the dir to exist yet
python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "<VAULT_PATH>"
```

Capture the absolute path as `VAULT_ABS`.

Check whether `VAULT_ABS` already exists:

```bash
if [ -e "<VAULT_ABS>" ]; then
  if [ -d "<VAULT_ABS>" ] && [ -z "$(ls -A "<VAULT_ABS>" 2>/dev/null)" ]; then
    echo "EMPTY_DIR"
  else
    echo "EXISTS_NONEMPTY"
  fi
else
  echo "DOES_NOT_EXIST"
fi
```

- `DOES_NOT_EXIST` or `EMPTY_DIR` → proceed to step 3
- `EXISTS_NONEMPTY` → **stop** and reply:
  ```
  Target already exists and is not empty: <VAULT_ABS>
  Choose a different path or remove the existing directory first.
  ```

## Step 3: Copy the template

```bash
mkdir -p "<VAULT_ABS>" && cp -R "${CLAUDE_PLUGIN_ROOT}/template/." "<VAULT_ABS>/"
```

## Step 4: Verify

```bash
ls -la "<VAULT_ABS>"
ls -la "<VAULT_ABS>/wiki"
ls -la "<VAULT_ABS>/raw"
test -f "<VAULT_ABS>/WIKI.md" && echo "WIKI.md: OK" || echo "WIKI.md: MISSING"
```

Confirm the tree contains `WIKI.md`, `raw/` (with `handovers/`), and `wiki/` (with `index.md`, `log.md`, `overview.md`, `sources/`, `entities/`, `concepts/`).

## Step 5: Report

Reply to the user with:

```
Vault created at: <VAULT_ABS>

Next steps:
  1. Set the active vault environment variable:
       export CLAUDE_MEMORY_VAULT="<VAULT_ABS>"
     (add to ~/.zshrc or ~/.bashrc for persistence)
  2. Drop source documents into: <VAULT_ABS>/raw/
  3. Ingest them: /wiki-ingest <file>
  4. Query the wiki: /wiki-query "your question"

Automatic capture of Claude conversations kicks in once
$CLAUDE_MEMORY_VAULT is set. PreCompact and SessionEnd hooks write
handover files to <VAULT_ABS>/raw/handovers/<session-id>.md.
```
