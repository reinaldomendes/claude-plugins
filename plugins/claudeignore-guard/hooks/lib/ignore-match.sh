#!/bin/bash
# ignore-match.sh — decide whether a path is excluded by `.claudeignore` (and, by
# default, by the project's `.gitignore` files as well).
#
# There is no pattern matching in this file. Git already implements gitignore
# semantics — negation, anchoring, `**`, directory-only rules, nested files,
# precedence — and re-implementing that in bash means owning every subtle
# difference forever. So git does the matching, on a MIRROR.
#
# The mirror exists because git cannot be asked to honour a chosen set of ignore
# files: `git check-ignore` run against the project always folds in whatever the
# repo's own `.gitignore` says, with no way to include or exclude it selectively.
# The mirror gives us that control — we decide exactly which rules go into it.
#
#   project/                      mirror/
#     .gitignore          ─┐
#     .claudeignore       ─┴──→     .gitignore      (concatenated, .claudeignore last)
#                                   .ci-split       (how many lines came from .gitignore)
#     pkg/.gitignore      ─┐
#     pkg/.claudeignore   ─┴──→     pkg/.gitignore  + pkg/.ci-split
#
# `.claudeignore` lines go LAST so that, under gitignore's last-match-wins rule,
# they always have the final say — including `!` negations. `.gitignore` can never
# override `.claudeignore`; only the reverse.
#
# `check-ignore` evaluates paths as strings, so this also answers for files that
# do not exist yet — a `Write` to a new path is covered — and it works even when
# the project is not a git repository at all, because the mirror carries its own.
#
# CLAUDEIGNORE_NO_GITIGNORE=1 leaves `.gitignore` out and honours `.claudeignore`
# alone.

# Directories never worth descending into when looking for ignore files.
_CI_PRUNE=( -name .git -o -name node_modules -o -name vendor -o -name .netlify )

# Is the project's own .gitignore merged in? Default yes.
_ci_merge_enabled() { [ "${CLAUDEIGNORE_NO_GITIGNORE:-0}" != "1" ]; }

# The candidate names, in merge order, as an ARRAY set once per invocation.
# Everything on the per-call path avoids `$( )`: a command substitution forks, and
# at ~1ms a fork the freshness loop was costing 30× the git query it protects.
_CI_NAMES=( .gitignore .claudeignore )
_ci_set_names() {
  if _ci_merge_enabled; then _CI_NAMES=( .gitignore .claudeignore )
  else _CI_NAMES=( .claudeignore ); fi
}

# Path of the mirror tree for a project root.
#
# The MODE is part of the identity, not just the project. A mirror built with the
# merge on holds .gitignore rules baked into its merged files; flipping
# CLAUDEIGNORE_NO_GITIGNORE would otherwise keep enforcing them, because the
# freshness pass only rebuilds directories whose SOURCES changed — and flipping a
# flag changes no source. Two mirrors also let sessions in different modes run
# concurrently without rebuilding each other's work on every call.
_ci_mirror_dir() {
  local mode=merged
  _ci_merge_enabled || mode=claudeonly
  printf '%s/claudeignore-guard/%s-%s' \
    "${TMPDIR:-/tmp}" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" "$mode"
}

# cat a file, guaranteeing it ends in a newline. Without this a source whose last
# line lacks one would fuse with the first line of the file appended after it,
# silently turning two rules into one nonsense rule.
_ci_cat_nl() {
  [ -s "$1" ] || return 0
  cat "$1"
  [ -n "$(tail -c1 "$1")" ] && echo
  return 0
}

# Build one directory's merged ignore file plus its .ci-split provenance marker.
# $1=project root  $2=mirror  $3=relative dir ("." for the root)
_ci_merge_dir() {
  local root="$1" mirror="$2" rel="$3" out split=0
  local src_gi src_ci
  src_gi="$root/${rel:+$rel/}.gitignore"; src_gi="${src_gi/\/.\//\/}"
  src_ci="$root/${rel:+$rel/}.claudeignore"; src_ci="${src_ci/\/.\//\/}"
  [ "$rel" = "." ] && { src_gi="$root/.gitignore"; src_ci="$root/.claudeignore"; }

  mkdir -p "$mirror/$rel" 2>/dev/null || return 1
  out="$mirror/$rel/.gitignore"; out="${out/\/.\//\/}"

  : > "$out" || return 1
  if _ci_merge_enabled && [ -f "$src_gi" ]; then
    _ci_cat_nl "$src_gi" >> "$out"
    split=$(grep -c '' < "$out" 2>/dev/null || echo 0)
  fi
  [ -f "$src_ci" ] && _ci_cat_nl "$src_ci" >> "$out"

  # The whole provenance scheme is this one integer: lines 1..split came from
  # .gitignore, everything after came from .claudeignore.
  printf '%s\n' "$split" > "${out%.gitignore}.ci-split"
  [ -s "$out" ]
}

# The two candidate names, in merge order. Under the opt-out only .claudeignore
# is considered — which also shrinks the discovery net, since a directory becomes
# "managed" by holding EITHER file.
_ci_names() {
  _ci_merge_enabled && printf '%s\n' .gitignore .claudeignore || printf '%s\n' .claudeignore
}

# Refresh the .track copies for one directory. A `cp -p` copy carries the source's
# own mtime, so the track file IS the stored mtime — nothing else to persist.
_ci_track_dir() {
  local root="$1" mirror="$2" rel="$3" name src trk base mbase
  if [ "$rel" = "." ]; then base="$root"; mbase="$mirror"
  else base="$root/$rel"; mbase="$mirror/$rel"; fi
  for name in "${_CI_NAMES[@]}"; do
    src="$base/$name"; trk="$mbase/$name.track"
    if [ -f "$src" ]; then cp -p "$src" "$trk" 2>/dev/null; else rm -f "$trk" 2>/dev/null; fi
  done
}

# Mirror ONE directory: merged file, provenance split, and track copies.
_ci_sync_dir() {
  _ci_merge_dir "$1" "$2" "$3"; local rc=$?
  _ci_track_dir "$1" "$2" "$3"
  return $rc
}

# Full discovery scan: walk the project for ignore files, mirror every directory
# holding one, and record the managed-directory manifest. This is the expensive
# step (a pruned `find`), so it runs once per session — see _ci_ensure.
_ci_scan() {
  local root="$1" mirror="$2" dir
  local -a names=( -name .claudeignore )
  _ci_merge_enabled && names=( \( -name .claudeignore -o -name .gitignore \) )

  find "$mirror" \( -name .gitignore -o -name .ci-split -o -name '*.track' \) -delete 2>/dev/null
  : > "$mirror/.ci-dirs"

  local sawroot=1
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ "$dir" = "." ] && sawroot=0
    _ci_sync_dir "$root" "$mirror" "$dir"
    printf '%s\n' "$dir" >> "$mirror/.ci-dirs"
  done < <(cd "$root" 2>/dev/null && find . \( "${_CI_PRUNE[@]}" \) -prune -o \
             "${names[@]}" -printf '%h\n' 2>/dev/null | sed 's#^\./##' | sort -u)

  # The root is ALWAYS managed, even with no ignore file in it today — that is what
  # makes a first-ever .claudeignore appearing there detectable without a rescan.
  [ "$sawroot" = 0 ] || printf '.\n' >> "$mirror/.ci-dirs"

  _ci_sync_info_exclude "$root" "$mirror"
}

_ci_sync_info_exclude() {
  local root="$1" mirror="$2"
  : > "$mirror/.git/info/exclude" 2>/dev/null
  _ci_merge_enabled && [ -f "$root/.git/info/exclude" ] &&
    cp "$root/.git/info/exclude" "$mirror/.git/info/exclude" 2>/dev/null
  return 0
}

# Cheap per-call freshness pass over the managed directories. Pure builtins in the
# common case: no subprocess unless something actually changed.
_ci_refresh() {
  local root="$1" mirror="$2" dir name src trk stale base mbase
  _CI_ACTIVE=1
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ "$dir" = "." ]; then base="$root"; mbase="$mirror"
    else base="$root/$dir"; mbase="$mirror/$dir"; fi
    stale=0
    for name in "${_CI_NAMES[@]}"; do
      src="$base/$name"; trk="$mbase/$name.track"
      if [ -f "$src" ]; then
        if [ ! -f "$trk" ]; then
          stale=1                                   # created since the last look
        elif [ "$src" -nt "$trk" ] || [ "$trk" -nt "$src" ]; then
          # Bidirectional: a plain -nt misses an mtime moving BACKWARDS (rsync -a,
          # restores from backup). The gate must mean "differs", not "is newer".
          if cmp -s "$src" "$trk"; then
            touch -r "$src" "$trk" 2>/dev/null     # same bytes: realign, no rebuild
          else
            stale=1
          fi
        fi
      elif [ -f "$trk" ]; then
        stale=1                                     # deleted since the last look
      fi
    done
    [ "$stale" = 1 ] && _ci_sync_dir "$root" "$mirror" "$dir"
    # "Is there anything to enforce?" answered with a builtin test as we go, so
    # _ci_ensure never has to shell out to `find` on the hot path.
    [ -s "$mbase/.gitignore" ] && _CI_ACTIVE=0
  done < "$mirror/.ci-dirs"

  _ci_sync_info_exclude "$root" "$mirror"
  [ -s "$mirror/.git/info/exclude" ] && _CI_ACTIVE=0
  return 0
}

# Ensure the mirror reflects the project, doing the least work that is still correct.
# Echoes the mirror path; returns non-zero when there is nothing to enforce.
_ci_ensure() {
  local root="$1" session="$2" mirror stamp

  local seen=""
  mirror=$(_ci_mirror_dir "$root")
  mkdir -p "$mirror" 2>/dev/null || return 1
  [ -d "$mirror/.git" ] || git -C "$mirror" init -q 2>/dev/null || return 1
  stamp="$mirror/.ci-stamp"
  _ci_set_names

  # Discovery is session-scoped rather than time-scoped: no clock, no tunable
  # staleness window. Anything already on the manifest is checked every call.
  # `read` is a builtin; `$(cat …)` here would fork on every single call.
  [ -f "$stamp" ] && read -r seen < "$stamp" 2>/dev/null
  if [ ! -s "$mirror/.ci-dirs" ] || [ -z "$session" ] || [ "$seen" != "$session" ]; then
    _ci_scan "$root" "$mirror"
    printf '%s\n' "$session" > "$stamp"
    _ci_refresh "$root" "$mirror"      # also computes _CI_ACTIVE
  else
    _ci_refresh "$root" "$mirror"
  fi

  [ "${_CI_ACTIVE:-1}" = 0 ] || return 1
  printf '%s' "$mirror"
}

# Translate a mirror hit back to the real source file and line.
# $1=mirror  $2="<mirror-relative-file>:<line>:<pattern>"
_ci_attribute() {
  local mirror="$1" hit="$2" file line pat dir split
  file="${hit%%:*}"; hit="${hit#*:}"
  line="${hit%%:*}"; pat="${hit#*:}"

  # info/exclude is copied verbatim, so it needs no translation.
  case "$file" in .git/info/exclude) printf '%s:%s:%s' "$file" "$line" "$pat"; return 0 ;; esac

  dir="${file%/.gitignore}"; [ "$dir" = "$file" ] && dir="."
  split=$(cat "$mirror/${dir#./}/.ci-split" 2>/dev/null)
  [ "$dir" = "." ] && split=$(cat "$mirror/.ci-split" 2>/dev/null)
  case "$split" in ''|*[!0-9]*) split=0 ;; esac

  if [ "$line" -le "$split" ]; then
    printf '%s:%s:%s' "${dir%/}/.gitignore" "$line" "$pat" | sed 's#^\./##'
  else
    printf '%s:%s:%s' "${dir%/}/.claudeignore" "$((line - split))" "$pat" | sed 's#^\./##'
  fi
}

# ci_is_ignored <abs-file-path> <project-root> [session-id]
# Returns 0 when the path is excluded, 1 otherwise.
# On a match, echoes "<source file>:<line>:<pattern>" so the caller can tell the
# user exactly which rule blocked them, in the file they actually edit.
# The session id scopes the discovery scan; omit it and every call rescans, which
# is correct but slower.
ci_is_ignored() {
  local target="$1" root="$2" session="${3:-}" mirror rel verdict
  command -v git >/dev/null 2>&1 || return 1

  # Only ever judge paths inside the project.
  case "$target" in "$root"/*) rel="${target#$root/}" ;; *) return 1 ;; esac

  mirror=$(_ci_ensure "$root" "$session") || return 1

  # The verdict comes from -q, NOT from -v. With -v, git exits 0 for ANY matching
  # rule *including a negation*, so `!.env.example` would read as "ignored". Only
  # -q means "this path is excluded".
  git -C "$mirror" check-ignore -q --no-index -- "$rel" 2>/dev/null || return 1

  # Excluded for sure; now re-ask with -v purely to recover which rule did it.
  verdict=$(git -C "$mirror" check-ignore -v --no-index -- "$rel" 2>/dev/null)
  [ -n "$verdict" ] || { printf 'an ignore rule'; return 0; }

  _ci_attribute "$mirror" "${verdict%%$'\t'*}"
}
