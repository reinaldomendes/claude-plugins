# claudeignore-guard

> Makes `.claudeignore` actually work. Claude Code has no native support for it — this
> hook enforces the file everyone already assumes is being enforced.

**Kind:** hooks · **Activates:** automatically while enabled
**Source:** [`plugins/claudeignore-guard/`](../)

## The problem

`.claudeignore` is **not a Claude Code feature.** It is one of the most-requested missing
ones — [#579](https://github.com/anthropics/claude-code/issues/579),
[#4160](https://github.com/anthropics/claude-code/issues/4160),
[#29455](https://github.com/anthropics/claude-code/issues/29455),
[#30810](https://github.com/anthropics/claude-code/issues/30810) — and there is a bug
report from people who assumed it worked:
[#36163 ".claudeignore does not prevent Claude from reading ignored files"](https://github.com/anthropics/claude-code/issues/36163).

Blog posts teach it as if it were native. So people write a `.claudeignore`, put `.env` at
the top, and believe their secrets are excluded — while nothing on the machine ever reads
the file. The failure is silent and looks exactly like success.

This plugin closes that gap: the file now means what everyone already thinks it means.

## What it does

A `PreToolUse` hook on `Read`, `Edit`, `Write` and `NotebookEdit`. If the target path
matches a `.claudeignore` rule, the call is **denied**, and the denial names the exact
file and line of the rule that blocked it:

```text
Blocked by .claudeignore: .env
Matched rule → /path/to/repo/.claudeignore:3: .env
```

That pointer matters — a pattern that blocks more than intended is otherwise a mystery.

## Scope — read this before trusting it

**Covered:** `Read`, `Edit`, `Write`, `NotebookEdit`.

**Not covered, deliberately:**

- **`Bash`.** Blocking `cat .env` requires parsing command strings, and a guard that
  scans them for filenames also blocks `echo "see .env for details"`. False positives on
  every shell command is a worse trade than the gap.
- **`Grep` / `Glob`.** They take a directory plus a pattern rather than a file path, so
  there is nothing to match a rule against without re-implementing their traversal. Grep
  in content mode can still surface a line from an ignored file.

**So this is context hygiene, not a security boundary.** It closes the common accidental
path — Claude opening `.env` while exploring — and nothing more. For a hard boundary use
`permissions.deny` in `settings.json`, which the harness enforces at every entry point:

```json
"permissions": { "deny": ["Read(./.env)", "Read(./secrets/**)"] }
```

The two compose well: `permissions.deny` for the handful of paths that must never be read,
`.claudeignore` for the long tail of noise you merely want out of context.

## Supported syntax

Full gitignore semantics, per `gitignore(5)`:

| Pattern | Meaning |
|---------|---------|
| `.env` | that basename, at any depth |
| `*.local` | glob on the basename; `*` does not cross `/` |
| `!.env.example` | re-include — **the last matching rule wins** |
| `/dist` | anchored to the `.claudeignore`'s own directory |
| `node_modules/` | directories only; everything beneath is excluded |
| `src/**/*.secret` | `**` crosses directory boundaries |
| `# comment`, blank lines | skipped; `\#` escapes a literal hash |

Excluding a directory excludes everything under it, so `dist` alone hides `dist/a/b.js`.

**Nested `.claudeignore` files are honoured.** Files from the project root down to the
target's own directory are applied in that order, each relative to its own directory — so a
deeper file's rule wins, exactly as git treats nested `.gitignore` files. A `!important.key`
in `pkg/.claudeignore` re-includes that one file under a root-level `*.key`.

### Why not `git check-ignore`

Because it always applies the repo's real `.gitignore` on top of whatever you point
`core.excludesFile` at. Every artifact the repo already ignores — `dist/`, `coverage/`,
generated sources — would come back as "ignored" too, and Claude would be blocked from
files it legitimately needs. Git offers no way to honour one ignore file in isolation, so
the matcher is hand-rolled in [`lib/ignore-match.sh`](../hooks/lib/ignore-match.sh).

## Install

```text
/plugin marketplace add https://github.com/reinaldomendes/reinaldo-open-plugins
/plugin install claudeignore-guard@reinaldo-open-plugins
```

Then create a `.claudeignore` at your project root. Enabling globally is safe — with no
`.claudeignore` present the hook exits immediately.

## Configuration

| Var | Default | Effect |
|-----|---------|--------|
| `CLAUDEIGNORE_DISABLED` | `0` | `1` = hook off entirely |
| `CLAUDEIGNORE_MODE` | `deny` | `warn` = allow the call but attach the reason. Useful while tuning patterns |

## Behavior notes

- Paths are resolved against `$CLAUDE_PROJECT_DIR`; relative `file_path` values work, and
  a file **outside** the project root is never matched — the hook never reaches into
  another repo.
- `Write` to a not-yet-existing path is matched too; the file needn't exist.
- A directory-only rule (`foo/`) matches the target itself only when it really is a
  directory, so a *file* named `foo` is not blocked by `foo/`.
- The hook denies via `hookSpecificOutput.permissionDecision`. A top-level
  `{"decision":"block"}` is the `Stop`/`PostToolUse` shape and is **ignored** for
  `PreToolUse` — using it would make the guard silently fail open.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| A file you need is blocked | Broader pattern than intended | The denial names the rule's file:line — narrow it, or re-include with `!` |
| Nothing is blocked | No `.claudeignore` at the project root, or `CLAUDEIGNORE_DISABLED=1` | Check the file's location; it must be inside `$CLAUDE_PROJECT_DIR` |
| A secret still reached context | It was read via `Bash` or `Grep` | Expected — see [Scope](#scope--read-this-before-trusting-it); use `permissions.deny` |
| `!pattern` doesn't re-include | An earlier rule excluded a **parent directory** | Git behaves the same way: re-include the directory first, then the file |

Run it by hand:

```bash
echo '{"tool_input":{"file_path":".env"}}' \
  | CLAUDE_PROJECT_DIR=$PWD bash plugins/claudeignore-guard/hooks/claudeignore-guard.sh
```

Empty output = allowed. A JSON body with `"permissionDecision":"deny"` = blocked.

## Files

```text
plugins/claudeignore-guard/
  .claude-plugin/plugin.json
  hooks/
    hooks.json               # PreToolUse(Read|Edit|Write|NotebookEdit)
    claudeignore-guard.sh    # decision + denial message
    lib/ignore-match.sh      # gitignore-syntax matcher
```

## Requirements

`bash` and `jq`. Nothing is installed on your behalf.

---

[← Marketplace README](../../../README.md)
