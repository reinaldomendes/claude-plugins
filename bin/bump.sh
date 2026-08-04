#!/usr/bin/env bash
# bump.sh — bump plugin semver version(s) in plugin.json.
#
# Usage:
#   bin/bump.sh <plugin> [patch|minor|major] [--commit]
#   bin/bump.sh --all     [patch|minor|major] [--commit]
#
# Default level is patch. Writes plugins/<plugin>/.claude-plugin/plugin.json in place.
# With --commit it also creates an isolated commit of just the bumped manifest(s):
#   single : chore(<plugin>): bump to <version>
#   --all  : chore(release): bump all plugins (<level>)   [+ per-plugin body]
# Pure bash + jq — no npm toolchain (jq is already a hard dependency of the test suite).

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "bump: $*" >&2; exit 1; }

level="patch"; all=false; commit=false; plugin=""
for arg in "$@"; do
  case "$arg" in
    --all)              all=true ;;
    --commit|-c)        commit=true ;;
    patch|minor|major)  level="$arg" ;;
    -*)                 die "unknown option '$arg'" ;;
    *)                  [ -z "$plugin" ] && plugin="$arg" || die "unexpected argument '$arg'" ;;
  esac
done

$all && [ -n "$plugin" ] && die "give either <plugin> or --all, not both"
$all || [ -n "$plugin" ] || die "usage: bin/bump.sh <plugin>|--all [patch|minor|major] [--commit]"

# echo the bumped version for a single plugin manifest; also appends to global arrays
bumped_paths=(); bumped_lines=()
bump_one() {
  local p="$1" manifest cur major minor patch new
  manifest="$REPO/plugins/$p/.claude-plugin/plugin.json"
  [ -f "$manifest" ] || die "no such plugin manifest: plugins/$p/.claude-plugin/plugin.json"
  cur=$(jq -r '.version // empty' "$manifest")
  [ -n "$cur" ] || die "$p has no .version in its manifest"
  [[ "$cur" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "$p version '$cur' is not X.Y.Z semver"
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
  case "$level" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  new="$major.$minor.$patch"
  local tmp; tmp=$(mktemp)
  jq --arg v "$new" '.version = $v' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
  echo "bumped $p $cur -> $new ($level)"
  bumped_paths+=("plugins/$p/.claude-plugin/plugin.json")
  bumped_lines+=("$p: $cur -> $new")
}

if $all; then
  found=false
  for dir in "$REPO"/plugins/*/; do
    [ -f "$dir.claude-plugin/plugin.json" ] || continue
    found=true; bump_one "$(basename "$dir")"
  done
  $found || die "no plugins found under plugins/"
else
  bump_one "$plugin"
fi

if $commit; then
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "--commit needs a git work tree"
  if $all; then
    subject="chore(release): bump all plugins ($level)"
    body=$(printf '%s\n' "${bumped_lines[@]}")
    git -C "$REPO" commit -q -m "$subject" -m "$body" -- "${bumped_paths[@]}"
  else
    new="${bumped_lines[0]##*-> }"
    git -C "$REPO" commit -q -m "chore($plugin): bump to $new" -- "${bumped_paths[@]}"
  fi
  echo "committed: ${#bumped_paths[@]} manifest(s)"
fi
