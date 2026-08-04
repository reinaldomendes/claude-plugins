# claudeignore-guard

> Makes `.claudeignore` actually work — and, by default, enforces your `.gitignore` too,
> so a repo that already guards its secrets is protected with no setup at all.

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

## What it does

A `PreToolUse` hook on `Read`, `Edit`, `Write` and `NotebookEdit`. If the target path is
excluded, the call is **denied**, naming the exact file and line of the rule that blocked
it and how to undo it:

```text
Blocked by .gitignore: node_modules/vue/package.json
Matched rule → .gitignore:10:node_modules

This rule comes from .gitignore, which claudeignore-guard merges in by default. To allow
this path, add to .claudeignore:

    !node_modules/

Re-include the OUTERMOST excluded directory — '!<dir>/**' and '!<dir>/<file>' do
nothing while a parent directory is excluded. Or set CLAUDEIGNORE_NO_GITIGNORE=1 to
drop .gitignore entirely, or CLAUDEIGNORE_DISABLED=1 to turn the guard off.
```

**`.gitignore` is merged in by default.** A repo with a good `.gitignore` and no
`.claudeignore` at all is still protected — install the plugin globally once and every repo
that already keeps its secrets out of git keeps them out of context. `.claudeignore` rules
are applied **last**, so they always win on conflict: `.gitignore` can never override
`.claudeignore`, only the reverse.

`CLAUDEIGNORE_NO_GITIGNORE=1` opts out and honours `.claudeignore` alone. Because that mode
fails *silently*, a `SessionStart` notice tells you how many rules are being skipped.

## Scope — read this before trusting it

**Covered:** `Read`, `Edit`, `Write`, `NotebookEdit`.

**Not covered, deliberately:**

- **`Bash`.** Blocking `cat .env` requires parsing command strings, and a guard that scans
  them for filenames also blocks `echo "see .env for details"`. False positives on every
  shell command is a worse trade than the gap.
- **`Grep` / `Glob`.** They take a directory plus a pattern rather than a file path, so
  there is nothing to match a rule against without re-implementing their traversal.

**So this is context hygiene, not a security boundary.** For a hard boundary use
`permissions.deny` in `settings.json`, which the harness enforces at every entry point:

```json
"permissions": { "deny": ["Read(./.env)", "Read(./secrets/**)"] }
```

## Hooks

| Event | Matcher | Script | Behavior |
|-------|---------|--------|----------|
| `PreToolUse` | `Read\|Edit\|Write\|NotebookEdit` | [`claudeignore-guard.sh`](../hooks/claudeignore-guard.sh) | **Denies** an excluded path, naming the rule |
| `SessionStart` | — | [`session-notice.sh`](../hooks/session-notice.sh) | Warns when `.gitignore` enforcement is switched **off** |

## How it matches: git does it, on a mirror

There is no pattern matching in this plugin. **Git implements gitignore semantics; this
plugin borrows them** rather than re-implementing negation, anchoring, `**`, directory
rules and precedence in bash and owning every subtle difference forever.

The obstacle is that `git check-ignore`, run against your project, always folds in whatever
that repo's `.gitignore` says, with no way to select which files count. The mirror gives us
that control:

```text
project/                       mirror/            (in $TMPDIR)
  .gitignore          ─┐
  .claudeignore       ─┴──→      .gitignore       concatenated, .claudeignore LAST
                                 .ci-split        how many lines came from .gitignore
                                 *.track          cp -p copies, for freshness
  pkg/.gitignore      ─┐
  pkg/.claudeignore   ─┴──→      pkg/.gitignore   + pkg/.ci-split
```

Three properties fall out for free:

- **Nested files and precedence** are git's own, not an approximation.
- **Paths that don't exist yet are answered correctly**, because `check-ignore` evaluates
  path strings — a `Write` to a new path is caught.
- **The project need not be a git repository at all.** `.gitignore` is read as plain text
  and the mirror carries its own `.git`.

The verdict comes from `check-ignore -q`. With `-v`, git exits **0 for any matching rule
including a negation**, so `!.env.example` would read as "ignored"; `-v` runs only
afterwards, to recover which rule matched.

**Provenance.** The merged file would lose the `file:line` pointer, so each directory gets a
`.ci-split` holding one integer: lines 1..split came from `.gitignore`, the rest from
`.claudeignore`. Without it a denial names the wrong file — worse than naming none, since it
sends you to edit a file that doesn't contain the rule.

## Supported syntax

Whatever `gitignore(5)` says, because git is doing the matching:

| Pattern | Meaning |
|---------|---------|
| `.env` | that basename, at any depth |
| `*.local` | glob on the basename; `*` does not cross `/` |
| `!.env.example` | re-include — **the last matching rule wins** |
| `/dist` | anchored to that ignore file's own directory |
| `node_modules/` | directories only; everything beneath is excluded |
| `src/**/*.secret` | `**` crosses directory boundaries |
| `# comment`, blank lines | skipped; `\#` escapes a literal hash |

### The re-include trap

`gitignore(5)`: *"It is not possible to re-include a file if a parent directory of that file
is excluded."* This is the single most likely thing to confuse you, so it is worth reading
twice. Only one of these does what it looks like:

```gitignore
/dist            # excludes the dist DIRECTORY …
!dist/client/    # … so this re-includes nothing. dist/client/a.js stays blocked.

dist/*           # excludes dist's CONTENTS, dist itself is not excluded …
!dist/client/    # … so this works. dist/client/a.js is readable.
```

And the rule is **re-include the outermost excluded directory, then narrow** — not merely
"re-include the directory". With `/inert` excluded, `!inert/foo` does nothing, because
`inert` above it is still excluded. This works:

```gitignore
# .gitignore:      /inert
!/inert/                    # re-open the OUTERMOST excluded directory first
/inert/must-be-secret/      # then narrow again
!inert/foo                  # and this now does real work
```

Both forms are pinned in the test suite, because the difference is invisible until
something you need is silently unreadable.

## Install

```text
/plugin marketplace add https://github.com/reinaldomendes/reinaldo-open-plugins
/plugin install claudeignore-guard@reinaldo-open-plugins
```

Enabling globally is safe: with no `.gitignore` and no `.claudeignore` the hook exits
immediately.

## Configuration

| Var | Default | Effect |
|-----|---------|--------|
| `CLAUDEIGNORE_DISABLED` | `0` | `1` = hook off entirely |
| `CLAUDEIGNORE_NO_GITIGNORE` | `0` | `1` = ignore `.gitignore` and `.git/info/exclude`; honour `.claudeignore` alone |
| `CLAUDEIGNORE_MODE` | `deny` | `warn` = allow the call but attach the reason. Useful while tuning patterns |
| `CLAUDEIGNORE_QUIET` | `0` | `1` = silence the `SessionStart` notice |

### What the opt-out really costs

More than it looks. Beyond losing `.gitignore` enforcement, it **shrinks the discovery
net**: a directory becomes "managed" by holding *either* ignore file, so in a repo with six
`.gitignore` files and two `.claudeignore` files, merged mode watches six directories for a
newly created `.claudeignore` and the opt-out watches two.

## Freshness — no cache staleness to reason about

Each mirrored source has a `.track` copy made with `cp -p`, so the track file carries the
source's own mtime and nothing else needs storing. Per call, for every managed directory:

1. **Bidirectional mtime gate** — `[ src -nt trk ] || [ trk -nt src ]`, pure builtins.
   Bidirectional because a plain `-nt` misses an mtime moving *backwards* (`rsync -a`,
   restores from backup); the test must mean "differs", not "is newer".
2. Gate false → nothing to do.
3. Gate true → compare content. Different → rebuild that directory. Same → `touch -r` only,
   which absorbs `git checkout` rewriting mtimes without a pointless rebuild.
4. Source gone but its directory managed → **deletion**. Source present with no track →
   **creation**. Both rebuild.

`.ci-dirs` lists the managed directories, and **the root is always one** — that is what
makes a first-ever `.claudeignore` appearing there take effect on the very next call.

**There is no time-based interval and nothing to tune.** Discovery of ignore files in
*new* directories is scoped to the session: one `find` per session, keyed on `session_id`.
So: editing, deleting or creating an ignore file in a known directory applies immediately;
one created mid-session in a directory that never had either file applies next session.

### Cost

Measured on a ~900-file Vue monorepo (1812 directories, 6 `.gitignore`, 2 `.claudeignore`):

| | before this design | now |
|---|---|---|
| first call of a session | — | ~132ms (one full `find` + mirror build) |
| every call after | ~85ms | **~30ms** |

Of that 30ms, ~19ms is a single `jq` invocation parsing the hook input — measured, and the
reason the hook parses its input exactly once. `git check-ignore` itself is under 1ms.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| A file you need is blocked | A `.gitignore` rule you forgot applies to Claude now | The denial names the rule and the exact `!` line to add |
| `!dir/file` didn't help | A parent directory is excluded | Re-include the **outermost** excluded directory first, then narrow |
| Nothing is blocked | No ignore files, or `CLAUDEIGNORE_DISABLED=1` | Both are intentional silent exits |
| A secret still reached context | It was read via `Bash` or `Grep` | Expected — see [Scope](#scope--read-this-before-trusting-it); use `permissions.deny` |
| "`.gitignore` is NOT enforced" at session start | `CLAUDEIGNORE_NO_GITIGNORE=1` is set | Unset it, or `CLAUDEIGNORE_QUIET=1` to accept the trade silently |
| A new `.claudeignore` seems ignored | It was created mid-session in a directory that had no ignore file | Applies next session, or delete `$TMPDIR/claudeignore-guard` |

Run it by hand:

```bash
echo '{"session_id":"x","tool_input":{"file_path":".env"}}' \
  | CLAUDE_PROJECT_DIR=$PWD bash plugins/claudeignore-guard/hooks/claudeignore-guard.sh
```

Empty output = allowed. A JSON body with `"permissionDecision":"deny"` = blocked.

## Files

```text
plugins/claudeignore-guard/
  .claude-plugin/plugin.json
  hooks/
    hooks.json               # PreToolUse(Read|Edit|Write|NotebookEdit) + SessionStart
    claudeignore-guard.sh    # the decision, the denial message and its escape hint
    session-notice.sh        # warns when .gitignore enforcement is switched off
    lib/ignore-match.sh      # mirror build, merge, provenance, freshness
```

## Requirements

`bash`, `jq` and `git` — git does the pattern matching, so it is required even when the
project itself is not a git repository. Nothing is installed on your behalf.

---

[← Marketplace README](../../../README.md)
