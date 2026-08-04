#!/usr/bin/env bash
# run-tests.sh — deterministic tests for the reinaldo-open-plugins marketplace.
# Runs everything that does NOT need a live Claude Code session: structure, JSON,
# shell syntax, and the hook decision logic.
#
# Usage:  bash test/run-tests.sh
# Results: written to $RESULTS (printed at the end).

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESULTS="${HOME}/reinaldo-open-plugins-test-results.txt"
: > "$RESULTS"

pass=0; fail=0; skip=0
log()  { echo "$*" | tee -a "$RESULTS"; }
ok()   { pass=$((pass+1)); log "  PASS  $*"; }
no()   { fail=$((fail+1)); log "  FAIL  $*"; }
sk()   { skip=$((skip+1)); log "  SKIP  $*"; }
sect() { log ""; log "== $* =="; }

log "reinaldo-open-plugins test run"
log "repo: $REPO"
log "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo n/a)"

# ------------------------------------------------------------------ structure
sect "Structure & manifests"
for f in "$REPO/.claude-plugin/marketplace.json" \
         "$REPO"/plugins/*/.claude-plugin/plugin.json \
         "$REPO"/plugins/*/hooks/hooks.json; do
  [ -f "$f" ] || continue
  if jq -e . "$f" >/dev/null 2>&1; then ok "valid JSON: ${f#$REPO/}"; else no "invalid JSON: ${f#$REPO/}"; fi
done
# every marketplace source path resolves to a plugin dir with a manifest
while IFS= read -r src; do
  [ -f "$REPO/${src#./}/.claude-plugin/plugin.json" ] && ok "source resolves: $src" || no "source missing plugin.json: $src"
done < <(jq -r '.plugins[].source' "$REPO/.claude-plugin/marketplace.json" 2>/dev/null)
# marketplace entries and plugin dirs agree
mp=$(jq -r '.plugins[].name' "$REPO/.claude-plugin/marketplace.json" 2>/dev/null | sort | tr '\n' ' ')
fs=$(find "$REPO/plugins" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')
[ "$mp" = "$fs" ] && ok "marketplace list matches plugins/ ($mp)" || no "marketplace=[$mp] vs plugins/=[$fs]"
# every plugin has docs and a semver version
for d in "$REPO"/plugins/*/; do
  p=$(basename "$d")
  [ -f "$d/docs/README.md" ] && ok "docs present: $p" || no "missing docs/README.md: $p"
  v=$(jq -r '.version // empty' "$d/.claude-plugin/plugin.json" 2>/dev/null)
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "semver version: $p ($v)" || no "bad version for $p: '$v'"
  n=$(jq -r '.name // empty' "$d/.claude-plugin/plugin.json" 2>/dev/null)
  [ "$n" = "$p" ] && ok "manifest name matches dir: $p" || no "manifest name '$n' != dir '$p'"
done
# every shell script is executable
nonx=$(find "$REPO/plugins" "$REPO/bin" "$REPO/.githooks" -name '*.sh' -o -name 'pre-push' 2>/dev/null | while read -r f; do [ -x "$f" ] || echo "${f#$REPO/}"; done)
[ -z "$nonx" ] && ok "all scripts are executable" || no "not executable: $nonx"

# ------------------------------------------------------------------ syntax
sect "Shell syntax (bash -n)"
while IFS= read -r s; do
  if bash -n "$s" 2>/dev/null; then ok "bash -n ${s#$REPO/}"; else no "bash -n ${s#$REPO/}"; fi
done < <(find "$REPO/plugins" "$REPO/bin" "$REPO/.githooks" -type f \( -name '*.sh' -o -name 'pre-push' \) | sort)

# ------------------------------------------------------------------ ignore matcher
sect "claudeignore-guard: gitignore-syntax matcher"
MATCH="$REPO/plugins/claudeignore-guard/hooks/lib/ignore-match.sh"
# shellcheck source=/dev/null
source "$MATCH"
T=$(mktemp -d); mkdir -p "$T"/{env,src/deep,dist/client,node_modules/pkg,logs,pkg/sub}
cat > "$T/.claudeignore" <<'EOF'
# a comment
*.local
.env
.env.*
!.env.example
env/.env.*
dist/*
!dist/client/
/build
!build/keep/
node_modules/
src/**/*.secret
logs/
*.key
EOF
printf '!important.key\n' > "$T/pkg/.claudeignore"
for f in .env .env.production .env.example foo.local env/.env.esf-us dist/app.js dist/client/a.js \
         node_modules/pkg/index.js src/deep/a.secret src/deep/a.ts logs/out.txt README.md build/keep/x.js \
         a.key pkg/important.key pkg/sub/other.key; do
  mkdir -p "$(dirname "$T/$f")"; touch "$T/$f"
done
mcase() { # $1=relpath $2=expect(ignored|allowed)
  local got; if ci_is_ignored "$T/$1" "$T" >/dev/null; then got=ignored; else got=allowed; fi
  [ "$got" = "$2" ] && ok "$2: $1" || no "$1 -> $got (want $2)"
}
mcase .env                     ignored
mcase .env.production          ignored
mcase .env.example             allowed   # negation, last match wins
mcase foo.local                ignored
mcase env/.env.esf-us          ignored   # unanchored basename glob at depth
mcase dist/app.js              ignored   # dist/* hides the contents
mcase dist/client/a.js         allowed   # `dir/*` + `!dir/keep/` — the idiom that DOES re-include
mcase build/keep/x.js          ignored   # `/build` excludes the dir itself, so nothing inside can be
                                         # re-included — gitignore(5). The `dir/*` form above is the
                                         # only one that works; this case pins the difference.
mcase node_modules/pkg/index.js ignored  # dir-only rule
mcase src/deep/a.secret        ignored   # ** crosses directories
mcase src/deep/a.ts            allowed
mcase logs/out.txt             ignored
mcase README.md                allowed
mcase a.key                    ignored
mcase pkg/important.key        allowed   # nested .claudeignore wins
mcase pkg/sub/other.key        ignored   # nested rule doesn't over-reach
# a file OUTSIDE the project root is never matched
ci_is_ignored "/etc/hostname" "$T" >/dev/null && no "path outside root should never match" || ok "path outside project root is never matched"

# ------------------------------------------------------------------ hook decisions
sect "claudeignore-guard: hook decisions"
HOOK="$REPO/plugins/claudeignore-guard/hooks/claudeignore-guard.sh"
hrun() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | env -u CLAUDEIGNORE_DISABLED -u CLAUDEIGNORE_MODE "${@:2}" CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null; }
o=$(hrun "$T/.env"); d=$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
[ "$d" = "deny" ] && ok "ignored path -> deny" || no "want deny, got '$d'"
[ "$(echo "$o" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" = "PreToolUse" ] \
  && ok "uses the PreToolUse decision shape (not the ignored top-level 'decision')" || no "wrong hook output shape"
echo "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '.claudeignore:' \
  && ok "denial names the rule's file:line" || no "denial should cite the matching rule"
o=$(hrun "$T/README.md"); [ -z "$o" ] && ok "allowed path -> no output" || no "allowed path should be silent: $o"
o=$(hrun "a.key"); [ "$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecision')" = "deny" ] \
  && ok "relative file_path resolves against CLAUDE_PROJECT_DIR" || no "relative path not resolved"
o=$(hrun "$T/.env" CLAUDEIGNORE_MODE=warn); [ "$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecision')" = "allow" ] \
  && ok "CLAUDEIGNORE_MODE=warn allows with a reason" || no "warn mode should allow"
o=$(hrun "$T/.env" CLAUDEIGNORE_DISABLED=1); [ -z "$o" ] && ok "CLAUDEIGNORE_DISABLED=1 disables the hook" || no "disable flag ignored"
o=$(printf '{"tool_input":{}}' | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null); [ -z "$o" ] \
  && ok "missing file_path -> no-op" || no "should no-op without a file_path"
o=$(hrun "/etc/hostname"); [ -z "$o" ] && ok "file outside the project -> no-op" || no "should not touch other repos"
# no .claudeignore at all -> silent
E=$(mktemp -d); touch "$E/x.ts"
o=$(printf '{"tool_input":{"file_path":"%s"}}' "$E/x.ts" | CLAUDE_PROJECT_DIR="$E" bash "$HOOK" 2>/dev/null)
[ -z "$o" ] && ok "no .claudeignore present -> silent no-op" || no "should no-op without a .claudeignore"
rm -rf "$T" "$E"

# ------------------------------------------------------------------ .gitignore merge
sect "claudeignore-guard: .gitignore merge (default) + CLAUDEIGNORE_NO_GITIGNORE opt-out"

# Run the hook against an arbitrary project. Env assignments may be appended.
gverdict() { # $1=project $2=relpath [ENV=VAL ...]
  local o; o=$(printf '{"tool_input":{"file_path":"%s"}}' "$1/$2" \
    | env -u CLAUDEIGNORE_DISABLED -u CLAUDEIGNORE_MODE -u CLAUDEIGNORE_NO_GITIGNORE \
        "${@:3}" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null)
  if [ -z "$o" ]; then echo allow; else echo "$o" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
gcase() { # $1=project $2=relpath $3=want(deny|allow) $4=label [ENV=VAL ...]
  local got; got=$(gverdict "$1" "$2" "${@:5}")
  [ "$got" = "$3" ] && ok "$4" || no "$4 — got '$got', want '$3'"
}
gwhy() { # $1=project $2=relpath [ENV=VAL ...] -> the "Matched rule → …" line
  printf '{"tool_input":{"file_path":"%s"}}' "$1/$2" \
    | env -u CLAUDEIGNORE_DISABLED -u CLAUDEIGNORE_MODE -u CLAUDEIGNORE_NO_GITIGNORE \
        "${@:3}" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | sed -n 2p
}
pcase() { # $1=project $2=relpath $3=want-substring $4=label [ENV=VAL ...]
  local why; why=$(gwhy "$1" "$2" "${@:5}")
  case "$why" in *"$3"*) ok "$4" ;; *) no "$4 — rule was '$why', wanted '*$3*'" ;; esac
}

# --- the case the default exists for: .gitignore only, no .claudeignore -------------
A=$(mktemp -d); mkdir -p "$A/secrets"
printf '/secrets/*\n!/secrets/*.example\n' > "$A/.gitignore"
touch "$A/secrets/mysuppersecret" "$A/secrets/something.example" "$A/README.md"
gcase "$A" secrets/mysuppersecret    deny  "merge: .gitignore-only repo blocks a gitignored file"
gcase "$A" secrets/something.example allow "merge: !/secrets/*.example re-includes"
gcase "$A" README.md                 allow "merge: unmatched path stays readable"
gcase "$A" secrets/mysuppersecret    allow "isolated: the secret LEAKS — this is why merge is the default" CLAUDEIGNORE_NO_GITIGNORE=1
pcase "$A" secrets/mysuppersecret ".gitignore:1" "merge: denial names .gitignore:1"

# --- acceptance scenario 1: no .git at all; .gitignore fights .claudeignore ---------
B=$(mktemp -d); mkdir -p "$B/dist"
printf '/dist\n'  > "$B/.claudeignore"
printf '!/dist\n' > "$B/.gitignore"
touch "$B/dist/somefile"
[ ! -d "$B/.git" ] && ok "scenario 1: fixture is not a git repo (enforcement must not need one)" \
                   || no "scenario 1 fixture unexpectedly has .git"
gcase "$B" dist/somefile deny "scenario 1 merged: .claudeignore beats the .gitignore negation"
gcase "$B" dist/somefile deny "scenario 1 isolated: .claudeignore alone denies" CLAUDEIGNORE_NO_GITIGNORE=1
pcase "$B" dist/somefile ".claudeignore:1" "scenario 1 merged: winner attributed to .claudeignore, not .gitignore"

# --- acceptance scenario 3a: /inert/* — both sources attributed in one fixture ------
C=$(mktemp -d); mkdir -p "$C/inert/must-be-secret"
printf '/inert/*\n'                 > "$C/.gitignore"
printf '/inert/must-be-secret/\n'   > "$C/.claudeignore"
touch "$C/inert/must-be-secret/something" "$C/inert/other.txt"
gcase "$C" inert/must-be-secret/something deny "3a: .claudeignore rule denies"
gcase "$C" inert/other.txt                deny "3a: .gitignore rule denies"
pcase "$C" inert/must-be-secret/something ".claudeignore:1" "3a provenance: merged line 2 → .claudeignore:1"
pcase "$C" inert/other.txt                ".gitignore:1"    "3a provenance: merged line 1 → .gitignore:1"
printf '/inert/must-be-secret/\n!/inert/other.txt\n' > "$C/.claudeignore"
gcase "$C" inert/other.txt                allow "3a: !/inert/other.txt re-includes across the merge"
gcase "$C" inert/must-be-secret/something deny  "3a: re-inclusion is surgical, not blanket"

# --- acceptance scenario 3b: /inert — the directory itself is excluded --------------
D=$(mktemp -d); mkdir -p "$D/inert/must-be-secret"
printf '/inert\n' > "$D/.gitignore"
printf '/inert/must-be-secret/\n!/inert/other.txt\n' > "$D/.claudeignore"
touch "$D/inert/other.txt" "$D/inert/must-be-secret/something"
gcase "$D" inert/other.txt deny "3b: re-include impossible when the parent DIRECTORY is excluded"

# --- acceptance scenario 4a/4b: a nested .gitignore under an excluded tree ----------
E4=$(mktemp -d); mkdir -p "$E4/inert/foo/bar" "$E4/inert/must-be-secret"
printf '/inert\n'        > "$E4/.gitignore"
printf '/innersecrets\n' > "$E4/inert/foo/.gitignore"
printf '/inert/must-be-secret/\n!inert/foo\n' > "$E4/.claudeignore"
touch "$E4/inert/foo/something" "$E4/inert/foo/bar/baz.txt" "$E4/inert/foo/innersecrets" \
      "$E4/inert/other.txt" "$E4/inert/must-be-secret/something"
gcase "$E4" inert/foo/something   deny "4a: !inert/foo is powerless at the wrong level"
gcase "$E4" inert/foo/bar/baz.txt deny "4a: depth does not matter"
gcase "$E4" inert/foo/innersecrets allow "4a isolated: nested .gitignore unread — innersecrets LEAKS" CLAUDEIGNORE_NO_GITIGNORE=1
printf '!/inert/\n/inert/must-be-secret/\n!inert/foo\n' > "$E4/.claudeignore"
gcase "$E4" inert/foo/something            allow "4b: !/inert/ at the outermost level re-opens the tree"
gcase "$E4" inert/other.txt                allow "4b: sibling content re-opened too"
gcase "$E4" inert/must-be-secret/something deny  "4b: narrowing after the re-include still holds"
gcase "$E4" inert/foo/innersecrets         deny  "4b: the nested .gitignore comes alive once its parent is re-included"
pcase "$E4" inert/foo/innersecrets "inert/foo/.gitignore:1" "4b provenance: attributed to the NESTED .gitignore"
pcase "$E4" inert/must-be-secret/something ".claudeignore:2" "4b provenance: attributed to .claudeignore:2"

# --- .git/info/exclude ---------------------------------------------------------------
F4=$(mktemp -d); git -C "$F4" init -q
printf 'sekret.txt\n' > "$F4/.git/info/exclude"; touch "$F4/sekret.txt"
gcase "$F4" sekret.txt deny "info/exclude is honoured under merge"
printf '!sekret.txt\n' > "$F4/.claudeignore"
gcase "$F4" sekret.txt allow ".claudeignore ! overrides info/exclude (it ranks lowest)"

# --- concatenation hygiene ------------------------------------------------------------
G4=$(mktemp -d); mkdir -p "$G4/a" "$G4/b"
printf '/a'    > "$G4/.gitignore"      # deliberately NO trailing newline
printf '/b\n'  > "$G4/.claudeignore"
touch "$G4/a/x" "$G4/b/x"
gcase "$G4" a/x deny "no-trailing-newline: the .gitignore rule survives the merge"
gcase "$G4" b/x deny "no-trailing-newline: the .claudeignore rule is not fused onto it"

# --- per-directory merge, modelled on packages/triggers/ ------------------------------
H4=$(mktemp -d); mkdir -p "$H4/pkg" "$H4/other"
printf '/root-only\n' > "$H4/.gitignore"
printf '*.log\n'      > "$H4/pkg/.gitignore"
printf '!keep.log\n'  > "$H4/pkg/.claudeignore"
touch "$H4/pkg/x.log" "$H4/pkg/keep.log" "$H4/other/y.log"
gcase "$H4" pkg/x.log    deny  "per-dir merge: the nested .gitignore applies in its own directory"
gcase "$H4" pkg/keep.log allow "per-dir merge: the nested .claudeignore negation wins there"
gcase "$H4" other/y.log  allow "per-dir merge: a sibling directory is unaffected"
pcase "$H4" pkg/x.log "pkg/.gitignore:1" "per-dir provenance: resolved against that directory's own split"

# --- freshness: everything below runs inside ONE session, so the per-call track
#     gate is what makes it pass — not the session-scoped rescan ---------------------
FR=$(mktemp -d); mkdir -p "$FR/pkg" "$FR/late"
printf '/a\n' > "$FR/.claudeignore"
touch "$FR/a" "$FR/b" "$FR/pkg/c" "$FR/late/d"
fcase() { # $1=relpath $2=want $3=label
  local o got
  o=$(printf '{"session_id":"S1","tool_input":{"file_path":"%s"}}' "$FR/$1" \
      | env -u CLAUDEIGNORE_DISABLED -u CLAUDEIGNORE_NO_GITIGNORE CLAUDE_PROJECT_DIR="$FR" bash "$HOOK" 2>/dev/null)
  if [ -z "$o" ]; then got=allow; else got=$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecision'); fi
  [ "$got" = "$2" ] && ok "$3" || no "$3 — got '$got', want '$2'"
}
fcase a deny  "freshness: baseline rule applies"
fcase b allow "freshness: unmatched path readable"
sleep 0.01; printf '/a\n/b\n' > "$FR/.claudeignore"
fcase b deny  "freshness: EDITING an ignore file takes effect on the next call"
sleep 0.01; printf '/a\n' > "$FR/.claudeignore"
fcase b allow "freshness: removing the rule takes effect on the next call"
# creating a second ignore file in an already-managed directory (the root)
sleep 0.01; printf '/b\n' > "$FR/.gitignore"
fcase b deny  "freshness: CREATING .gitignore beside .claudeignore is caught without a rescan"
# a content-free touch must not rebuild the merged file
MIR=$(printf '%s' "$FR" | cksum | cut -d' ' -f1); MIR="${TMPDIR:-/tmp}/claudeignore-guard/$MIR"
before=$(stat -c %Y "$MIR/.gitignore" 2>/dev/null)
sleep 1.1; touch "$FR/.claudeignore"; fcase a deny "freshness: content-free touch still verdicts correctly"
after=$(stat -c %Y "$MIR/.gitignore" 2>/dev/null)
[ "$before" = "$after" ] && ok "freshness: a touch with identical content does NOT rebuild the merged file" \
                         || no "touch rebuilt the merged file ($before -> $after)"
# an mtime moved BACKWARDS is still detected (plain -nt would miss it)
printf '/a\n/b\n/zzz\n' > "$FR/.claudeignore"; touch -d '1 hour ago' "$FR/.claudeignore"
fcase zzz deny "freshness: an mtime moved BACKWARDS is still detected (bidirectional gate)"
# a NEW ignore file in a previously-unknown directory needs the next session
sleep 0.01; printf '/d\n' > "$FR/late/.claudeignore"   # anchored to late/, so this means late/d
fcase late/d allow "freshness: a new dir's ignore file waits for the next session (documented gap)"
o=$(printf '{"session_id":"S2","tool_input":{"file_path":"%s"}}' "$FR/late/d" \
    | env -u CLAUDEIGNORE_DISABLED -u CLAUDEIGNORE_NO_GITIGNORE CLAUDE_PROJECT_DIR="$FR" bash "$HOOK" 2>/dev/null)
[ "$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] \
  && ok "freshness: a new session rescans and picks it up" || no "new session should rescan"
rm -rf "$FR"

# --- isolated-mode notice -------------------------------------------------------------
NOTICE="$REPO/plugins/claudeignore-guard/hooks/session-notice.sh"
if [ -f "$NOTICE" ]; then
  nrun() { printf '{"session_id":"t","hook_event_name":"SessionStart"}' \
    | env -u CLAUDEIGNORE_QUIET "${@:2}" CLAUDE_PROJECT_DIR="$1" bash "$NOTICE" 2>/dev/null; }
  o=$(nrun "$A" CLAUDEIGNORE_NO_GITIGNORE=1)
  [ -n "$o" ] && ok "notice: fires in isolated mode when a .gitignore exists" || no "notice should fire"
  echo "$o" | jq -e '.systemMessage // .hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
    && ok "notice: emits systemMessage or additionalContext" || no "notice emitted no user-facing field"
  o=$(nrun "$A"); [ -z "$o" ] && ok "notice: silent in merge mode" || no "notice should be silent by default"
  o=$(nrun "$A" CLAUDEIGNORE_NO_GITIGNORE=1 CLAUDEIGNORE_QUIET=1)
  [ -z "$o" ] && ok "notice: CLAUDEIGNORE_QUIET=1 silences it" || no "QUIET should silence the notice"
  o=$(nrun "$B" CLAUDEIGNORE_NO_GITIGNORE=1)   # .gitignore holds only a negation -> nothing lost
  [ -z "$o" ] && ok "notice: silent when the ignore files hold no real exclusion (no crying wolf)" \
              || no "notice should not fire when nothing would be lost"
  o=$(nrun "$E4" CLAUDEIGNORE_NO_GITIGNORE=1)  # the rule lives in a NESTED .gitignore
  echo "$o" | grep -q 'innersecrets\|[0-9]' && ok "notice: counts nested .gitignore rules too" \
                                            || no "notice must count nested .gitignore files"
else
  no "notice: hooks/session-notice.sh does not exist yet"
fi
rm -rf "$A" "$B" "$C" "$D" "$E4" "$F4" "$G4" "$H4"

# ------------------------------------------------------------------ release tooling
sect "release tooling: bump.sh + pre-push gate"
BUMP="$REPO/bin/bump.sh"; HOOKF="$REPO/.githooks/pre-push"
for f in "$BUMP" "$HOOKF"; do
  [ -f "$f" ] && bash -n "$f" 2>/dev/null && ok "bash -n ${f#$REPO/}" || no "syntax/missing: ${f#$REPO/}"
  [ -x "$f" ] && ok "executable: ${f#$REPO/}" || no "not executable: ${f#$REPO/}"
done
if command -v git >/dev/null 2>&1; then
  wr=$(mktemp -d); mkdir -p "$wr/plugins/foo/.claude-plugin" "$wr/bin"
  printf '{"name":"foo","version":"1.0.0"}\n' > "$wr/plugins/foo/.claude-plugin/plugin.json"
  cp "$BUMP" "$wr/bin/bump.sh"
  out=$(bash "$wr/bin/bump.sh" foo patch 2>&1)
  [ "$(jq -r .version "$wr/plugins/foo/.claude-plugin/plugin.json")" = "1.0.1" ] && ok "bump.sh patch 1.0.0 -> 1.0.1" || no "patch bump failed: $out"
  bash "$wr/bin/bump.sh" foo minor >/dev/null 2>&1
  [ "$(jq -r .version "$wr/plugins/foo/.claude-plugin/plugin.json")" = "1.1.0" ] && ok "bump.sh minor -> 1.1.0" || no "minor bump failed"
  bash "$wr/bin/bump.sh" foo major >/dev/null 2>&1
  [ "$(jq -r .version "$wr/plugins/foo/.claude-plugin/plugin.json")" = "2.0.0" ] && ok "bump.sh major -> 2.0.0" || no "major bump failed"
  bash "$wr/bin/bump.sh" nosuch patch >/dev/null 2>&1 && no "bump.sh should fail on unknown plugin" || ok "bump.sh rejects an unknown plugin"
  rm -rf "$wr"
else
  sk "git not available — release tooling end-to-end"
fi

# ------------------------------------------------------------------ summary
sect "SUMMARY"
log "PASS=$pass  FAIL=$fail  SKIP=$skip"
echo
echo "================================================================"
echo "Results written to: $RESULTS"
echo "PASS=$pass FAIL=$fail SKIP=$skip"
echo "================================================================"
[ "$fail" -eq 0 ]
