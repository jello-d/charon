#!/bin/sh
# tools.t - every shipped script PARSES under its own shell (dash for POSIX sh,
# bash for bash scripts), dispatched by shebang. A parse error ships a broken
# command; this is the cheapest guard against it.
. "$(dirname "$0")/lib.sh"
harness_init tools

_checker() {   # <file> -> the -n syntax check for its shebang
  case "$(head -1 "$1")" in
    *bash) bash -n "$1" ;;
    *python*) python3 -m py_compile "$1" ;;
    *) dash -n "$1" 2>/dev/null || sh -n "$1" ;;
  esac
}

_n=0
for _f in "$HERE"/bin/* "$HERE"/libexec/* "$HERE"/setup.sh "$HERE"/test/run; do
  [ -f "$_f" ] || continue
  _checker "$_f" || fail "parse error in $(basename "$_f")"
  _n=$((_n + 1))
done

# STATIC ANALYSIS, when the tool is available. A parse check proves the script
# runs; it says nothing about quoting a path with a space, an unguarded rm -rf,
# or `A && B || C` not being if-then-else. shellcheck found a real one here: an
# empty MOUNT would have turned a cleanup into `rm -rf "/.charon-probe"`.
# Skipped rather than failed when absent, so the suite still runs anywhere.
if command -v shellcheck >/dev/null 2>&1; then
  _sc=$(shellcheck -s sh -f gcc "$HERE"/bin/* "$HERE"/libexec/* \
          "$HERE/setup.sh" 2>/dev/null) || :
  [ -z "$_sc" ] || fail "shellcheck findings:
$_sc"
  _n=$((_n + 1))
fi

pass "$_n scripts parse"
