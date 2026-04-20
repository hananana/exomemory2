---
description: Create a new external memory vault (defaults to ~/vault)
argument-hint: "[vault-path]"
allowed-tools: Bash
---

# /wiki-init

Initialize a new external memory vault. Follow the steps below using the `Bash` tool. **Do not act until you have parsed and validated the argument.**

## Arguments

The user-supplied argument is:

```
$ARGUMENTS
```

## Step 1: Resolve the argument

If `$ARGUMENTS` is empty or contains only whitespace, use the **default vault path `~/vault`** and call it `VAULT_PATH`.

Otherwise, take the **first whitespace-separated token** as the target vault path and call it `VAULT_PATH`. Do not split on quotes; assume the user passes a single path.

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

Confirm the tree contains `WIKI.md`, `raw/` (with `handovers/`), `wiki/` (with `index.md`, `log.md`, `overview.md`, `sources/`, `entities/`, `concepts/`), and `.obsidian/` (with `app.json`, `appearance.json`, `core-plugins.json`, `graph.json`).

## Step 4.5: Detect Obsidian

The vault template ships with an `.obsidian/` preset (graph color groups for sources/entities/concepts, recommended core plugins). Obsidian is not required — the wiki is plain Markdown — but it is the recommended frontend for Karpathy's original UX (Graph View, Backlinks, Web Clipper, Dataview).

Run the following to check whether Obsidian is available:

```bash
OBSIDIAN_FOUND=0
if [ "$(uname)" = "Darwin" ]; then
  if [ -d "/Applications/Obsidian.app" ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
    OBSIDIAN_FOUND=1
  fi
else
  if command -v obsidian >/dev/null 2>&1; then
    OBSIDIAN_FOUND=1
  fi
fi
echo "OBSIDIAN_FOUND=$OBSIDIAN_FOUND"
```

Capture the result as `OBSIDIAN_FOUND` (`0` or `1`). Use it to tailor Step 5.

## Step 5: Report

Reply to the user with:

```
Vault created at: <VAULT_ABS>

Next steps:
  1. Set the active vault environment variable:
       export EXOMEMORY_VAULT="<VAULT_ABS>"
     (add to ~/.zshrc or ~/.bashrc for persistence)
  2. Drop source documents into: <VAULT_ABS>/raw/
  3. Ingest them: /wiki-ingest <file>
  4. Query the wiki: /wiki-query "your question"
```

Then append **one of the following** depending on `OBSIDIAN_FOUND`:

**If `OBSIDIAN_FOUND=1`:**

```
  5. (Recommended) Open the vault in Obsidian to get Graph View, Backlinks, etc.:
       File → Open folder as vault → <VAULT_ABS>
     The bundled .obsidian/ preset enables core plugins and color-codes
     sources / entities / concepts in the graph.
```

**If `OBSIDIAN_FOUND=0`:**

```
  5. (Recommended) Install Obsidian to use the bundled .obsidian/ preset:
       macOS:   brew install --cask obsidian
       Other:   https://obsidian.md/download
     After installing, open the vault: File → Open folder as vault → <VAULT_ABS>
     Without Obsidian, the wiki still works as plain Markdown in any editor.
```

Finally, always append:

```
Automatic capture of Claude conversations kicks in once
$EXOMEMORY_VAULT is set. PreCompact and SessionEnd hooks write
handover files to <VAULT_ABS>/raw/handovers/<session-id>.md.
```
