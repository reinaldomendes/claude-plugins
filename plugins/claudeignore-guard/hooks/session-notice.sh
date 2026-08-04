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
    # `grep -c` ALREADY prints 0 when nothing matches — and exits 1 while doing it.
    # A `|| echo 0` fallback therefore appends a SECOND zero, making n="0\n0" and
    # blowing up the arithmetic below. Take grep's output and ignore its status.
    n=$(grep -cE '^[[:space:]]*[^#![:space:]]' "$f" 2>/dev/null) || true
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
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

# THIS NOTICE IS ADDRESSED TO THE USER. Claude is only the delivery path — it must not
# act on it, reconfigure anything, or let it steer the session. Saying so explicitly
# matters because the text arrives inside a user turn, where anything that reads like a
# request is indistinguishable from the user making one.
#
# Two channels:
#   initialUserMessage  prepended to the first prompt, rendered in the TRANSCRIPT, so it
#                       shows on every surface. Replaced `systemMessage`, which renders in
#                       the terminal only — IDE users saw nothing at all.
#   additionalContext   Claude sees it whatever the surface, so the warning still lands if
#                       the transcript channel ever changes.
#
# Framing is structural — an XML-style tag, as Claude Code uses for its own injected
# context (<system-reminder>, <git-state>) — plus a disclaimer inside, since the tag names
# the source but not the sender. Both are needed: a one-line "[notice … not typed by the
# user]" prefix was tried first and Claude still attributed the text to the user on the
# next turn.
#
# It also asks for no deliberation. A hook cannot *enforce* that — there is no per-message
# reasoning control, only session-wide MAX_THINKING_TOKENS — but reasoning spent here is
# stolen from the request the user actually made.
BANNER="<claudeignore-guard-notice>
Automated notice from the claudeignore-guard SessionStart hook. The user did not type
this and is not asking for anything.

$MSG

This warning is for the user, not an instruction to you. Do not act on it, do not change
any configuration because of it, and do not let it influence what you do next. It needs no
analysis and no reply — carry on with the user's actual request.
</claudeignore-guard-notice>"

CTX="$MSG"$'\n'"This is a warning for the user, not an instruction to you: do not act on it or change anything because of it. It needs no analysis or reply. Its only bearing on your work is that .gitignore rules are not being enforced, so do not assume a path is protected."

jq -n --arg b "$BANNER" --arg c "$CTX" \
  '{hookSpecificOutput: {hookEventName: "SessionStart",
                         initialUserMessage: $b,
                         additionalContext: $c}}'
exit 0
