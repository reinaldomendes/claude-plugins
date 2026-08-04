#!/bin/bash
# ignore-match.sh — decide whether a path is excluded by a `.claudeignore`.
#
# There is no pattern matching in this file. Git already implements gitignore
# semantics — negation, anchoring, `**`, directory-only rules, nested files,
# precedence — and re-implementing that in bash means owning every subtle
# difference forever. So git does the matching, on a MIRROR.
#
# The mirror exists because git cannot be asked to honour one ignore file in
# isolation: `git check-ignore` always folds in the repo's own `.gitignore`, so
# every build artifact the repo already ignores (dist/, coverage/, node_modules/)
# would come back "ignored" and Claude would be blocked from files it needs.
#
# So: copy each `.claudeignore` into a scratch tree at the same relative path,
# named `.gitignore`, and ask git about THAT tree. Nothing else lives there, so
# the answer reflects `.claudeignore` and nothing else.
#
#   project/                     mirror/
#     .claudeignore        →       .gitignore
#     pkg/.claudeignore    →       pkg/.gitignore
#
# `check-ignore` evaluates paths as strings, so this also answers for files that
# do not exist yet — a `Write` to a new path is covered, which a worktree scan
# (`git ls-files`) cannot do.

# Directories never worth descending into to find a .claudeignore.
_CI_PRUNE=( -name .git -o -name node_modules -o -name vendor -o -name .netlify )

# Path of the mirror tree for a project root.
_ci_mirror_dir() {
  printf '%s/claudeignore-guard/%s' \
    "${TMPDIR:-/tmp}" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

# Mirror every .claudeignore under $1 into a scratch git tree. Cheap: a handful of
# tiny copies. Stale entries are cleared first so a deleted .claudeignore stops
# applying. Echoes the mirror path; returns non-zero if there is nothing to mirror.
_ci_sync_mirror() {
  local root="$1" mirror rel found=1
  mirror=$(_ci_mirror_dir "$root")

  mkdir -p "$mirror" 2>/dev/null || return 1
  [ -d "$mirror/.git" ] || git -C "$mirror" init -q 2>/dev/null || return 1
  find "$mirror" -name .gitignore -delete 2>/dev/null

  while IFS= read -r rel; do
    found=0
    mkdir -p "$mirror/$(dirname "$rel")" 2>/dev/null || continue
    cp "$root/$rel" "$mirror/${rel%.claudeignore}.gitignore" 2>/dev/null || continue
  done < <(cd "$root" && find . \( "${_CI_PRUNE[@]}" \) -prune -o -name .claudeignore -printf '%P\n' 2>/dev/null)

  [ "$found" = 0 ] || return 1
  printf '%s' "$mirror"
}

# ci_is_ignored <abs-file-path> <project-root>
# Returns 0 when the path is excluded, 1 otherwise.
# On a match, echoes "<.claudeignore path>:<line>: <pattern>" so the caller can
# tell the user exactly which rule blocked them.
ci_is_ignored() {
  local target="$1" root="$2" mirror rel verdict
  command -v git >/dev/null 2>&1 || return 1

  # Only ever judge paths inside the project.
  case "$target" in "$root"/*) rel="${target#$root/}" ;; *) return 1 ;; esac

  mirror=$(_ci_sync_mirror "$root") || return 1

  # The verdict comes from -q, NOT from -v. With -v, git exits 0 for ANY matching
  # rule *including a negation*, so `!.env.example` would read as "ignored". Only
  # -q means "this path is excluded".
  git -C "$mirror" check-ignore -q --no-index -- "$rel" 2>/dev/null || return 1

  # Excluded for sure; now re-ask with -v purely to recover which rule did it.
  # "<ignorefile>:<line>:<pattern>\t<path>"
  verdict=$(git -C "$mirror" check-ignore -v --no-index -- "$rel" 2>/dev/null)
  [ -n "$verdict" ] || { printf 'a .claudeignore rule'; return 0; }

  # Report the rule against the real file the user edits, not the mirror copy.
  verdict="${verdict%%$'\t'*}"
  verdict="${verdict/#.gitignore:/.claudeignore:}"
  verdict="${verdict//\/.gitignore:/\/.claudeignore:}"
  printf '%s' "$verdict"
}
