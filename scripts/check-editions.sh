#!/bin/bash
# Checks the rules the public export relies on (EDITIONS.md); no build. Run: scripts/check-editions.sh (or make check-editions).
#   - every file in Plus/ is wrapped whole in `#if RIBBON_PLUS ... #endif` and every file in Free/ in `#if !RIBBON_PLUS ... #endif`,
#     with no other conditional-compilation line inside;
#   - no two files of the app share a name (SwiftPM wants unique names in a target);
#   - no shared file has a conditional-compilation line that names RIBBON_PLUS (if one ever must, it needs an #else branch and
#     only #if / #else / #endif: unifdef keeps the #else branch and does not know #elseif);
#   - `unifdef -URIBBON_PLUS` (what the export runs) empties every Plus file and keeps the whole body of every Free file.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src=$root/app/Sources/Ribbon
# The exported public repo has no Plus/ folder, and unifdef has already unwrapped its Free/ files: nothing left to check there.
if [[ ! -d $src/Plus ]]; then printf 'check-editions: no Plus/ folder, so this is the exported tree: nothing to check\n'; exit 0; fi
fails=0
bad() { printf 'check-editions: %s\n' "$*" >&2; fails=$((fails + 1)); }
cond_lines() { grep -nE '^[[:space:]]*#(if|else|elseif|elif|endif)([[:space:]]|$)' "$1" || true; }

wrapped() {   # wrapped FILE OPEN: the first and the last line that is not blank are OPEN and #endif, and nothing else conditional is inside
  local f=$1 open=$2 first last n
  first=$(grep -vE '^[[:space:]]*$' "$f" | head -n 1)
  last=$(grep -vE '^[[:space:]]*$' "$f" | tail -n 1)
  [[ $first == "$open" ]] || bad "${f#"$root"/}: starts with '$first', not '$open'"
  [[ $last == "#endif" ]] || bad "${f#"$root"/}: ends with '$last', not '#endif'"
  n=$(cond_lines "$f" | wc -l | tr -d ' ')
  [[ $n == 2 ]] || bad "${f#"$root"/}: $n conditional-compilation lines, expected the opening #if and the closing #endif only"
}

shopt -s nullglob
plus_files=("$src"/Plus/*.swift)    # none in the exported public repo
free_files=("$src"/Free/*.swift)
for f in ${plus_files[@]+"${plus_files[@]}"}; do wrapped "$f" '#if RIBBON_PLUS'; done
for f in ${free_files[@]+"${free_files[@]}"}; do wrapped "$f" '#if !RIBBON_PLUS'; done

dups=$(find "$root/app/Sources" -name '*.swift' -exec basename {} \; | sort | uniq -d)
[[ -z $dups ]] || bad "file names used twice: $(echo "$dups" | tr '\n' ' ')"

while IFS= read -r f; do
  case $f in "$src"/Plus/*|"$src"/Free/*) continue ;; esac
  if cond_lines "$f" | grep -q RIBBON_PLUS; then
    bad "${f#"$root"/}: a shared file with a RIBBON_PLUS region (check it leaves valid Swift after unifdef -URIBBON_PLUS, and uses #else, not #elseif)"
  fi
done < <(find "$root/app/Sources" -name '*.swift')

if command -v unifdef >/dev/null 2>&1; then
  # unifdef lexes C. A Swift multi-line string (""") ends it with "Unterminated string literal" and output cut off at that line,
  # so the export runs it only on the files that name RIBBON_PLUS (Plus/ and Free/) and these must hold no such string.
  unifdef_ok() {   # unifdef_ok FILE: its output when it ran cleanly; fails (and says why) when unifdef gave up on the file
    local f=$1 rc=0
    UNIFDEF_OUT=$(unifdef -URIBBON_PLUS "$f" 2>&1) || rc=$?
    (( rc <= 1 )) || { bad "${f#"$root"/}: unifdef -URIBBON_PLUS cannot read it ($(printf '%s' "$UNIFDEF_OUT" | tail -n 2 | tr '\n' ' ')); no multi-line strings in Plus/ or Free/"; return 1; }
  }
  for f in ${plus_files[@]+"${plus_files[@]}"}; do
    unifdef_ok "$f" || continue
    [[ -z ${UNIFDEF_OUT//[[:space:]]/} ]] || bad "${f#"$root"/}: unifdef -URIBBON_PLUS leaves something of it"
  done
  for f in ${free_files[@]+"${free_files[@]}"}; do
    unifdef_ok "$f" || continue
    want=$(grep -vE '^[[:space:]]*#(if !RIBBON_PLUS|endif)[[:space:]]*$' "$f")
    [[ $UNIFDEF_OUT == "$want" ]] || bad "${f#"$root"/}: unifdef -URIBBON_PLUS does not keep exactly its body"
  done
else
  printf 'check-editions: unifdef not found (/usr/bin/unifdef), skipped\n' >&2
fi

if (( fails )); then printf 'check-editions: %d problem(s)\n' "$fails" >&2; exit 1; fi
printf 'check-editions: ok (%d Plus files, %d Free files)\n' "${#plus_files[@]}" "${#free_files[@]}"
