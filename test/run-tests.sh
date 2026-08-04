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
