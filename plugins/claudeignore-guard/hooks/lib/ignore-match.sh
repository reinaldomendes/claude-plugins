#!/bin/bash
# ignore-match.sh — gitignore-syntax matching for `.claudeignore` files.
#
# Why hand-rolled instead of `git check-ignore`: that command always applies the
# repo's real `.gitignore` on top of whatever you point `core.excludesFile` at, so
# every build artifact the repo already ignores (dist/, coverage/, generated
# sources) would come back as "ignored" too. There is no way to ask git to honour
# ONE ignore file in isolation, and over-blocking a generated file Claude legitimately
# needs is worse than the reimplementation.
#
# Semantics implemented, following gitignore(5):
#   - blank lines and `#` comments are skipped; `\#` escapes a literal hash
#   - `!pat` re-includes; LAST matching pattern wins
#   - a trailing `/` matches directories only
#   - a `/` anywhere but the end anchors the pattern to the .claudeignore's directory;
#     otherwise the pattern matches a basename at any depth
#   - `*` and `?` do not cross `/`; `**` does
#   - excluding a directory excludes everything under it
#
# Nested `.claudeignore` files are honoured: files from the project root down to the
# target's own directory are applied in that order, each relative to its own directory,
# so a deeper file's rule wins — the same precedence git gives nested .gitignore files.

# Convert one gitignore pattern body into an anchored ERE.
# Deliberately character-by-character: converting via sed risks a replacement being
# re-substituted by a later rule.
_ci_pattern_to_regex() {
  local pat="$1" out="" i=0 c next
  local len=${#pat}
  while [ "$i" -lt "$len" ]; do
    c="${pat:$i:1}"
    case "$c" in
      '*')
        next="${pat:$((i+1)):1}"
        if [ "$next" = "*" ]; then
          # `**/` → any number of leading dirs; `/**` or bare `**` → anything
          if [ "${pat:$((i+2)):1}" = "/" ]; then
            out+="(.*/)?"; i=$((i+3)); continue
          fi
          out+=".*"; i=$((i+2)); continue
        fi
        out+="[^/]*"; i=$((i+1)); continue
        ;;
      '?')  out+="[^/]" ;;
      '\')
        # escape sequence: take the next char literally
        next="${pat:$((i+1)):1}"
        [ -n "$next" ] && out+="\\$next" && i=$((i+2)) && continue
        out+="\\\\"
        ;;
      # ERE metacharacters that must survive as literals
      '.'|'+'|'('|')'|'|'|'^'|'$'|'{'|'}') out+="\\$c" ;;
      '['|']') out+="$c" ;;   # character classes pass through as-is
      *) out+="$c" ;;
    esac
    i=$((i+1))
  done
  printf '%s' "$out"
}

# ci_is_ignored <abs-file-path> <project-root>
# Returns 0 when the path is ignored, 1 otherwise.
# Echoes the winning "<ignorefile>:<lineno>:<pattern>" on stdout when ignored, so
# callers can tell the user WHICH rule blocked them.
ci_is_ignored() {
  local target="$1" root="$2"
  local ignored=1 why=""

  case "$target" in "$root"/*) ;; *) return 1 ;; esac

  # Every directory from the root down to the file's own, in that order.
  local rel_dir dirs=("$root") cur="$root"
  rel_dir="${target#$root/}"; rel_dir="$(dirname "$rel_dir")"
  if [ "$rel_dir" != "." ]; then
    local IFS='/' part
    for part in $rel_dir; do cur="$cur/$part"; dirs+=("$cur"); done
  fi

  local base ignorefile rel candidates cand pat neg dironly anchored rx lineno
  for base in "${dirs[@]}"; do
    ignorefile="$base/.claudeignore"
    [ -f "$ignorefile" ] || continue
    case "$target" in "$base"/*) rel="${target#$base/}" ;; *) continue ;; esac

    # the path plus every ancestor, so a rule matching a parent dir hides its contents
    candidates=("$rel"); cand="$rel"
    while [ "$(dirname "$cand")" != "." ]; do cand="$(dirname "$cand")"; candidates+=("$cand"); done

    lineno=0
    while IFS= read -r pat || [ -n "$pat" ]; do
      lineno=$((lineno+1))
      # strip trailing whitespace that isn't escaped, then skip blanks/comments
      pat="${pat%"${pat##*[![:space:]]}"}"
      [ -z "$pat" ] && continue
      case "$pat" in \#*) continue ;; '\#'*) pat="${pat#\\}" ;; esac

      neg=0; case "$pat" in '!'*) neg=1; pat="${pat#!}" ;; esac
      [ -z "$pat" ] && continue
      dironly=0; case "$pat" in */) dironly=1; pat="${pat%/}" ;; esac
      [ -z "$pat" ] && continue

      anchored=0
      case "$pat" in
        /*) anchored=1; pat="${pat#/}" ;;
        */*) anchored=1 ;;
      esac
      [ -z "$pat" ] && continue

      rx="$(_ci_pattern_to_regex "$pat")"

      local hit=0
      for cand in "${candidates[@]}"; do
        if [ "$anchored" = 1 ]; then
          [[ "$cand" =~ ^${rx}$ ]] || continue
        else
          # unanchored: match the basename at any depth
          [[ "$cand" =~ ^(.*/)?${rx}$ ]] || continue
        fi
        # a directory-only rule may not match the target itself unless it IS a directory
        if [ "$dironly" = 1 ] && [ "$cand" = "$rel" ] && [ ! -d "$base/$rel" ]; then
          continue
        fi
        hit=1; break
      done

      if [ "$hit" = 1 ]; then
        if [ "$neg" = 1 ]; then ignored=1; why=""
        else ignored=0; why="${ignorefile}:${lineno}: ${pat}"; fi
      fi
    done < "$ignorefile"
  done

  [ "$ignored" = 0 ] && printf '%s' "$why"
  return "$ignored"
}
