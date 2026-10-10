#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Five scans of what leaves this machine, run by hand before a commit, from an optional
# pre-push hook and in the CI. No network access.
#
#   scripts/checks.sh --staged [--fork]               the index
#   scripts/checks.sh --push [--fork] [REMOTE [URL]]  the outgoing commits, from the stdin
#                                                     lines of a pre-push hook
#   scripts/checks.sh --ci [--fork]                   the tracked files
#
# --fork checks the fork checkout external/FPGA-Companion instead of this game20k tree.
#   secrets        PASS, TOKEN and SSID of sdcard/config.ini (or G20K_CONFIG_INI), counted, never
#                  shown. Under 8 characters a value counts only as a word in a text file.
#                  Skipped only without config.ini (the CI), a key without a value is a finding.
#   paths          tracked files that .gitignore excludes, git add -f included, and build
#                  output: anything in a folder build, build_* or CMakeFiles
#   ra-conditions  RetroAchievements condition chains, conditions such as 0xH0010=5 joined
#                  by "_": sets belong to RetroAchievements. tests/**/selftest_* is exempt.
#   crlf           files whose line ends changed: a CRLF file stays CRLF
#   tests          the host tests (make -C tests/host), game20k tree only: the CI runs them
#                  too, but a push that fails there is already public
# Each scan prints its sample size, a sample of 0 is a finding. Exit 1 on a finding, 2 on
# usage errors.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INI=${G20K_CONFIG_INI:-$ROOT/sdcard/config.ini}
# one condition, "_", and the start of the next one. The interval keeps a stray "0x" in
# source text from pairing with another one far away on the same line
RA_RE='0x[ A-Za-z]?[0-9A-Fa-f]+[^_ ]{0,20}_[A-Z]?:?[dpb~]?0x'
# bytes, not characters: in a UTF-8 locale grep on macOS stops at the first invalid byte
LC_ALL=C; export LC_ALL

usage() { echo "usage: $0 --staged | --push [REMOTE [URL]] | --ci [--base REV], each with [--fork]" >&2; exit 2; }
MODE= REPO=$ROOT WHAT=game20k REMOTE= BASE=
while [ $# -gt 0 ]; do
  case $1 in
    --staged|--push|--ci) [ -z "$MODE" ] || usage; MODE=${1#--} ;;
    --fork) REPO=$ROOT/external/FPGA-Companion; WHAT=fork ;;
    --base) shift; BASE=$1 ;;
    -*) usage ;;
    *) [ "$MODE" = push ] || usage; [ -n "$REMOTE" ] || REMOTE=$1 ;;
  esac
  shift
done
[ -n "$MODE" ] || usage
# a hook exports the variables of the repository it runs in, the scans name theirs
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
cd "$REPO" || exit 2
T=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/g20k-checks.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
trap 'exit 2' HUP INT TERM
N=0 TIPS=
: > "$T/commits"
finding() { echo "FINDING $*"; N=$((N + 1)); }
say() { echo "  $*"; }
total() { awk -F: '{ s += $NF } END { print s + 0 }'; }
nonzero() { case $1 in *[!0]*) return 0 ;; *) return 1 ;; esac; }
GIT="git -c core.quotepath=off -c color.ui=never"
CR=$(printf '\r')

# git grep -c with "$@" over what this mode checks: the index, the tracked files, or the tree
# of each pushed tip. One "[<tip>:]<path>:<count>" line per file with a match.
tgrep() {
  case $MODE in
    staged) $GIT grep --cached -c "$@" ;;
    ci) $GIT grep -c "$@" ;;
    push) [ -z "$TIPS" ] || $GIT grep -c "$@" $TIPS ;;
  esac
  # exit 1 only means no match, anything above is an error that would read as "0 hits"
  rc=$?
  [ "$rc" -le 1 ] || echo "git grep $* exited with $rc" >> "$T/greperr"
  return 0
}

# hits <pattern file> <long|short>: lines holding one of the values of the file
hits() {
  [ -s "$1" ] || { echo 0; return; }
  if [ "$MODE" = push ]; then
    if [ "$2" = long ]; then grep -a -F -c -f "$1" "$T/text"; else grep -a -F -w -c -f "$1" "$T/plain"; fi
  elif [ "$2" = long ]; then tgrep -a -F -f "$1" | total
  else tgrep -I -F -w -f "$1" | total
  fi
}

check_secrets() {
  if [ ! -f "$INI" ]; then say "secrets: skipped, no config.ini here (the CI has none)"; return; fi
  # config.ini as the firmware reads it: "; comment", [SECTION], KEY=value ; comment. The
  # values go into files in the private temp folder, never onto a command line.
  awk -v d="$T" '{ sub(/\r$/, "") }
    /^[ \t]*[;[]/ || !index($0, "=") { next }
    { k = toupper(substr($0, 1, index($0, "=") - 1)); gsub(/[ \t]/, "", k)
      v = substr($0, index($0, "=") + 1); sub(/;.*/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v) }
    (k == "PASS" || k == "TOKEN" || k == "SSID") && v != "" && v !~ /^YOUR_/ {
      print v > (d "/" k (length(v) < 8 ? ".short" : ".long")) }' "$INI"
  out=
  for k in PASS TOKEN SSID; do
    touch "$T/$k.long" "$T/$k.short"
    v=$(cat "$T/$k.long" "$T/$k.short" | sort -u | wc -l | tr -d ' ')
    h=$(( $(hits "$T/$k.long" long) + $(hits "$T/$k.short" short) ))
    out="$out, $k $h hits ($v values)"
    [ "$v" -gt 0 ] || finding "secrets: config.ini has no $k value, the scan for it would be blind"
    [ "$h" -eq 0 ] || finding "secrets: $h lines hold a $k value"
  done
  say "secrets: ${out#, } in $SAMPLE"
}

check_paths() {
  if [ "$MODE" = push ]; then
    for c in $TIPS; do git ls-tree -r -z --name-only "$c"; done
  else
    git ls-files -z
  fi > "$T/names"
  FILES=$(tr -cd '\000' < "$T/names" | wc -c | tr -d ' ')
  # the user's global ignore file stays out, .gitignore is the only list
  git -c core.excludesFile=/dev/null check-ignore --no-index --stdin -z < "$T/names" \
    | tr '\000' '\n' | sort -u > "$T/ignored"
  say "paths: $FILES names checked against .gitignore, $(wc -l < "$T/ignored" | tr -d ' ') excluded"
  [ "$FILES" -gt 0 ] || finding "paths: no file to check"
  while IFS= read -r p; do finding "paths: $p is excluded by .gitignore"; done < "$T/ignored"
  # a build folder the .gitignore does not name yet: one finding per folder, not per file
  tr '\000' '\n' < "$T/names" | sed -n -E 's#^((.*/)?(build|build_[^/]*|CMakeFiles))/.*#\1#p' \
    | sort -u > "$T/builds"
  while IFS= read -r d; do finding "paths: $d/ is build output and tracked"; done < "$T/builds"
}

check_ra() {
  # counts per file only, the matching text would be the set
  tgrep -I -E "$RA_RE" | grep -v -E '(^|:)tests/(.*/)?selftest_[^/:]*:[0-9]+$' > "$T/ra"
  say "ra-conditions: $FILES files, $(wc -l < "$T/ra" | tr -d ' ') with a condition chain"
  while IFS= read -r l; do finding "ra-conditions: ${l%:*} has ${l##*:} lines like a condition chain"; done < "$T/ra"
}

# eol <old> [<new>]: files whose line ends changed from commit <old> to <new> (without <new>:
# the index). A candidate is a file whose numstat changes with --ignore-cr-at-eol. That also
# takes a newline added at the end of the file, so a file counts only when its number of
# lines with CR changes too. Adds the files compared to EOL_N.
eol() {
  if [ -n "$2" ]; then set -- "$1" "$2" "$1" "$2"; else set -- --cached "$1" "$1" ""; fi
  $GIT diff --numstat --no-renames --no-ext-diff "$1" "$2" > "$T/a"
  $GIT diff --numstat --no-renames --no-ext-diff --ignore-cr-at-eol "$1" "$2" > "$T/b"
  EOL_N=$((EOL_N + $(wc -l < "$T/a")))
  awk -F'\t' 'FILENAME == ARGV[1] { b[$3] = $1 " " $2; next } b[$3] != $1 " " $2 { print $3 }' \
    "$T/b" "$T/a" | while IFS= read -r p; do
    [ "$($GIT show "$3:$p" 2>/dev/null | grep -c "$CR")" = "$($GIT show "$4:$p" 2>/dev/null | grep -c "$CR")" ] ||
      printf '%s\n' "$p"
  done >> "$T/eol"
}

check_tests() {
  [ "$WHAT" = game20k ] && [ -f "$ROOT/tests/host/Makefile" ] || return 0
  if OUT=$(make -C "$ROOT/tests/host" 2>&1); then say "tests: $(printf '%s\n' "$OUT" | grep -o 'host tests: .*' | tail -1)"
  else printf '%s\n' "$OUT" | tail -12; finding "tests: the host tests failed (make -C tests/host)"; fi
}

check_crlf() {
  EOL_N=0; : > "$T/eol"
  # --ci compares with --base when given (the CI passes the commit before the push), so a
  # line end change in any commit of the push shows, otherwise with the parent of HEAD. For
  # the fork, the base is the gitlink that the base commit of game20k points at.
  from=
  if [ "$MODE" = ci ] && nonzero "$BASE"; then
    from=$BASE
    [ "$WHAT" = fork ] && from=$(git -C "$ROOT" rev-parse -q --verify "$BASE:external/FPGA-Companion")
    git rev-parse -q --verify "$from^{commit}" > /dev/null || { finding "crlf: base $BASE is not in this clone"; from=; }
  fi
  case $MODE in
    staged) git rev-parse -q --verify HEAD > /dev/null && eol HEAD ;;
    ci) if [ -n "$from" ]; then eol "$from" HEAD
        elif git rev-parse -q --verify HEAD^1 > /dev/null; then eol HEAD^1 HEAD; fi ;;
    push) while read -r c; do git rev-parse -q --verify "$c^1" > /dev/null && eol "$c^1" "$c"; done < "$T/commits" ;;
  esac
  crlf=$(git ls-files --eol | grep -c '^i/crlf')
  say "crlf: $crlf CRLF files tracked, $EOL_N changed files compared"
  [ "$crlf" -gt 0 ] || finding "crlf: no CRLF file tracked, the scan has nothing to protect"
  sort -u -o "$T/eol" "$T/eol"
  while IFS= read -r p; do finding "crlf: the line ends of $p changed"; done < "$T/eol"
}

echo "checks --$MODE ($WHAT):"
if [ "$MODE" = push ]; then
  # "<local ref> <local oid> <remote ref> <remote oid>" per line, a deletion carries nothing
  while read -r lref loid rref roid; do
    nonzero "$loid" || continue
    TIPS="$TIPS $(git rev-parse "$loid^{commit}")"
    [ "$(git cat-file -t "$loid")" = tag ] && git cat-file tag "$loid" >> "$T/tags"
    set -- "$loid" --not --remotes${REMOTE:+=$REMOTE}
    nonzero "$roid" && git cat-file -e "$roid^{commit}" 2> /dev/null && set -- "$@" "$roid"
    git rev-list "$@" >> "$T/commits" || finding "push: cannot list the commits of $lref"
  done
  sort -u -o "$T/commits" "$T/commits"
  [ -n "$TIPS" ] || { say "nothing outgoing"; exit 0; }
  # everything the commits carry, messages included: as text for the long values, with binary
  # files left out for the short ones
  : > "$T/text"; : > "$T/plain"
  if [ -s "$T/commits" ]; then
    set -- --no-walk=unsorted --stdin -p --no-ext-diff --no-textconv --diff-merges=first-parent \
      --format='commit %H%n%an <%ae>%n%cn <%ce>%n%B'
    $GIT log "$@" --text < "$T/commits" > "$T/text"
    $GIT log "$@" < "$T/commits" > "$T/plain"
  fi
  [ -f "$T/tags" ] && tee -a "$T/text" < "$T/tags" >> "$T/plain"
  SAMPLE="$(wc -l < "$T/commits" | tr -d ' ') commits, $(wc -l < "$T/text" | tr -d ' ') lines"
fi
check_paths
# the text the secret and RA scans read: lines of the tracked text files, or of the push
[ "$MODE" = push ] || SAMPLE="$FILES files, $(tgrep -I -c '' | total) text lines"
case $SAMPLE in *" 0 text lines"|*", 0 lines") finding "scan: no text to read ($SAMPLE)" ;; esac
check_secrets
check_ra
check_crlf
check_tests
if [ -s "$T/greperr" ]; then
  while IFS= read -r l; do finding "scan: $l, the scan result is not valid"; done < "$T/greperr"
fi

if [ "$N" -gt 0 ]; then echo "checks: $N findings, refused"; exit 1; fi
echo "checks: 0 findings"
