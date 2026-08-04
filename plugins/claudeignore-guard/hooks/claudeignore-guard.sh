#!/bin/bash
# claudeignore-guard.sh — PreToolUse hook. Enforces `.claudeignore`.
#
# `.claudeignore` is NOT a Claude Code feature. It is a long-standing feature request
# (anthropics/claude-code#579, #4160, #29455, #30810) and blog posts present it as if it
# were native — so people write one, list `.env` in it, and believe their secrets are
# protected while nothing reads the file. This hook makes the file mean what everyone
# already assumes it means.
#
# Blocks Read / Edit / Write / NotebookEdit on any path matched by a `.claudeignore`,
# using gitignore syntax (see lib/ignore-match.sh). The denial names the exact file and
# line of the rule that blocked it, so a wrong pattern is obvious rather than mysterious.
#
# NOT covered — stated plainly because a guard you misjudge is worse than none:
#   - `Bash`. Blocking `cat .env` needs command parsing, and a guard that scans command
#     strings for filenames blocks `echo "see .env for details"` too. Use
#     permissions.deny for a hard boundary.
#   - `Grep` / `Glob`. They take a directory plus a pattern, not a file path, so there is
#     nothing to match a rule against without re-implementing their traversal. Grep in
#     content mode can therefore still surface a line from an ignored file.
# Treat this as context hygiene that closes the common accidental path, not as a
# security boundary. `permissions.deny` in settings.json is the real boundary.
#
# Env: CLAUDEIGNORE_DISABLED=1  — turn the hook off entirely
#      CLAUDEIGNORE_MODE=warn   — allow with a warning instead of denying (default: deny)

set -uo pipefail

[ "${CLAUDEIGNORE_DISABLED:-0}" = "1" ] && exit 0

# shellcheck source=lib/ignore-match.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ignore-match.sh"

INPUT=$(cat)

# ONE jq call, not two. Measured on this machine: jq costs ~19ms per invocation
# while the git query it feeds costs under 1ms, so a second parse would be the
# single most expensive thing the hook does. `@sh` makes jq shell-quote the values,
# so eval is safe for paths containing spaces, quotes or newlines.
# SESSION_ID scopes the discovery scan — see _ci_ensure in lib/ignore-match.sh.
eval "$(printf '%s' "$INPUT" | jq -r '@sh "FILE_PATH=\(.tool_input.file_path // .tool_input.notebook_path // "") SESSION_ID=\(.session_id // "")"' 2>/dev/null)"
[ -n "${FILE_PATH:-}" ] || exit 0
SESSION_ID="${SESSION_ID:-}"

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || exit 0

# Resolve to an absolute path without requiring the file to exist (Write creates it).
case "$FILE_PATH" in
  /*) ABS="$FILE_PATH" ;;
  *)  ABS="$ROOT/$FILE_PATH" ;;
esac
# Collapse a leading ./ and any /./ so prefix comparisons hold.
ABS="${ABS//\/.\//\/}"

WHY=$(ci_is_ignored "$ABS" "$ROOT" "$SESSION_ID") || exit 0

REL="${ABS#$ROOT/}"
SRC="${WHY%%:*}"                 # which file the winning rule lives in
PAT="${WHY#*:}"; PAT="${PAT#*:}" # the rule itself

# The escape depends on WHAT the rule excluded. `dir/*` excludes the contents and
# leaves the directory itself un-excluded, so a file-level negation works. A bare
# `dir` excludes the directory, and then NOTHING inside can be re-included until
# the directory itself is — so the hint must name that directory, not the file.
case "$PAT" in
  */\*)              ESC="!/$REL" ;;
  */)                ESC="!${PAT}" ;;
  *\**|*\?*|*\[*)    ESC="!/$REL" ;;
  *) if [ -d "$ROOT/${PAT#/}" ]; then ESC="!${PAT%/}/"; else ESC="!/$REL"; fi ;;
esac

MSG="Blocked by $SRC: $REL
Matched rule → $WHY
"
case "$SRC" in
  *.claudeignore)
    MSG="$MSG
Adjust the rule in $SRC (a leading '!' re-includes), or set CLAUDEIGNORE_DISABLED=1." ;;
  *)
    MSG="$MSG
This rule comes from $SRC, which claudeignore-guard merges in by default. To allow
this path, add to .claudeignore:

    $ESC

Re-include the OUTERMOST excluded directory — '!<dir>/**' and '!<dir>/<file>' do
nothing while a parent directory is excluded. Or set CLAUDEIGNORE_NO_GITIGNORE=1 to
drop .gitignore entirely, or CLAUDEIGNORE_DISABLED=1 to turn the guard off." ;;
esac

if [ "${CLAUDEIGNORE_MODE:-deny}" = "warn" ]; then
  jq -n --arg r "$MSG" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}'
  exit 0
fi

# PreToolUse takes its decision from hookSpecificOutput.permissionDecision — a top-level
# {"decision":"block"} is the Stop/PostToolUse shape and is IGNORED here, which would
# make this guard fail open. See https://code.claude.com/docs/en/hooks.
jq -n --arg r "$MSG" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
