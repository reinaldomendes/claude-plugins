#!/bin/bash
# session-notice.sh — SessionStart hook. Warns, once per session, that `.gitignore`
# is NOT being enforced because CLAUDEIGNORE_NO_GITIGNORE=1 is set.
#
# Why only this direction: merge mode announces itself at the point of failure — a
# denial names the rule and how to undo it. Isolated mode fails *silently*, which is
# the exact failure this plugin exists to correct, so it is the mode that needs a
# voice. There is deliberately no matching notice for merge mode.
#
# It stays quiet unless the flag actually costs something: a repo with no real
# exclusions loses nothing by the flag, and a warning that cries wolf gets ignored
# precisely when it finally matters.
#
# Nested `.gitignore` files are counted too. A root-only count would report "nothing
# lost" for a repo whose protection lives in nested files — the very case that
# motivated the warning (see acceptance scenario 4a).
#
# Env: CLAUDEIGNORE_QUIET=1 silences it · CLAUDEIGNORE_DISABLED=1 disables the plugin

set -uo pipefail

[ "${CLAUDEIGNORE_DISABLED:-0}" = "1" ] && exit 0
[ "${CLAUDEIGNORE_QUIET:-0}" = "1" ] && exit 0
# Merge is on (the default) → nothing is being skipped → nothing to say.
[ "${CLAUDEIGNORE_NO_GITIGNORE:-0}" = "1" ] || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || exit 0

# A "real exclusion" is a line that actually withholds something: not blank, not a
# comment, not a negation. Only those are lost by turning the merge off.
count_rules() {
  local total=0 f n
  for f in "$@"; do
    [ -f "$f" ] || continue
    n=$(grep -cE '^[[:space:]]*[^#![:space:]]' "$f" 2>/dev/null || echo 0)
    total=$((total + n))
  done
  printf '%s' "$total"
}

mapfile -t GITIGNORES < <(cd "$ROOT" 2>/dev/null && find . \
  \( -name .git -o -name node_modules -o -name vendor -o -name .netlify \) -prune -o \
  -name .gitignore -printf "$ROOT/%P\n" 2>/dev/null)
[ -f "$ROOT/.git/info/exclude" ] && GITIGNORES+=("$ROOT/.git/info/exclude")

SKIPPED=$(count_rules "${GITIGNORES[@]:-}")
[ "${SKIPPED:-0}" -gt 0 ] || exit 0    # nothing would be lost — stay quiet

mapfile -t CLAUDEIGNORES < <(cd "$ROOT" 2>/dev/null && find . \
  \( -name .git -o -name node_modules -o -name vendor -o -name .netlify \) -prune -o \
  -name .claudeignore -printf "$ROOT/%P\n" 2>/dev/null)
APPLIED=$(count_rules "${CLAUDEIGNORES[@]:-}")

FILES=${#GITIGNORES[@]}
MSG=".gitignore is NOT enforced — CLAUDEIGNORE_NO_GITIGNORE=1 is set, so $SKIPPED rule(s) across $FILES ignore file(s) are being skipped. Only .claudeignore applies ($APPLIED rule(s)). Unset CLAUDEIGNORE_NO_GITIGNORE to restore merged enforcement, or CLAUDEIGNORE_QUIET=1 to silence this notice."

# systemMessage is the user-facing channel; additionalContext tells Claude, so it
# does not assume a file is protected when it is not.
jq -n --arg m "$MSG" \
  '{systemMessage: $m,
    hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0
