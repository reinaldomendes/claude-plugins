# `reinaldo-open-plugins`

Open-source Claude Code plugin marketplace. See [README.md](./README.md) for the plugin
list and install, [RELEASING.md](./RELEASING.md) for the versioning contract.

## Rules

- **This catalog is public.** Never commit anything project-specific, private, or
  identifying — no client names, internal paths, hostnames, tokens, or repo URLs from
  private work. Examples in docs use neutral placeholders.
- **Every plugin bumps its own version when its content changes.** The catalog floats, so
  `plugin.json` `version` *is* the release; the `pre-push` gate rejects a push that skips
  it. `bin/bump.sh <plugin> [level] [--commit]`.
- **`bash` + `jq` only.** No npm/python toolchain — a plugin that needs one is a plugin
  users can't install reliably.
- **Hooks no-op quietly rather than misfire.** Outside the project, without the tool
  installed, or with nothing to act on, exit 0 silently. A hook that blocks work it
  shouldn't is worse than one that does nothing.
- **Scope every path check to `$CLAUDE_PROJECT_DIR`** so a hook never reaches into an
  unrelated repo.
- **Document what a guard does NOT cover**, in its `docs/README.md`. A guard trusted where
  it doesn't apply is worse than no guard — that is the exact failure `claudeignore-guard`
  exists to correct.
- **Tests must be green** — `bash test/run-tests.sh` — before any push.

## Hook contract gotchas

- **`PreToolUse` decisions go in `hookSpecificOutput.permissionDecision`** (`deny`/`allow`).
  A top-level `{"decision":"block"}` is the `Stop`/`PostToolUse` shape and is **ignored**
  for `PreToolUse` — using it makes a guard silently fail open.
- **`Stop` hooks** take `{"decision":"block","reason":…}` on stdout, and must honor
  `stop_hook_active` or they loop forever.
- **stderr is only shown to Claude on a non-zero exit.** To inform without blocking, emit
  `hookSpecificOutput.additionalContext` and exit 0.
- **The default hook timeout is 60s.** Anything slower needs an explicit `"timeout"` in
  `hooks.json`.

## Commits

- **Format**: `type(scope): summary` (Conventional Commits). Types:
  `feat, fix, refactor, test, docs, chore, style`. Scope = the plugin name.
- **Subject**: imperative mood, one concise line naming the **main goal** of the change
  (the *why*, not a file list). Keep it short — target ≤72 chars.
- **Body**: usually omit. Add a line or two only when the *why* is non-obvious; never
  enumerate files or narrate each edit.
- Never commit bare `Update` / `Fix` / `Changes` / `WIP` messages.
- **Scope to the task**: commit only changes related to the current request. If the working
  tree has unrelated changes, leave them out by default and mention them.
- **One goal per commit**: if the changes span several unrelated goals, split them.
