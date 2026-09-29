#!/bin/sh
# tools.t - every shipped script PARSES under its own shell (dash for POSIX sh,
# bash for bash scripts), dispatched by shebang. A parse error ships a broken
# command; this is the cheapest guard against it.
. "$(dirname "$0")/harness_lib"
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

# 80 COLUMNS, the project's HARD rule, enforced by the SUITE rather than by a
# human remembering to run awk. It was not enforced anywhere until 2026-09-17,
# and a test file went in at 81 columns that same day. Covers the TESTS and the
# shipped example configs too: they are as much a delivered artifact as the
# code, and nothing was checking them.
_long=$(awk 'length>80 {printf "%s:%d (%d cols)\n", FILENAME, FNR, length}' \
  "$HERE"/bin/* "$HERE"/libexec/* "$HERE/setup.sh" "$HERE"/test/*.t \
  "$HERE/test/harness_lib" "$HERE/test/run" \
  "$HERE"/share/charon/*.conf 2>/dev/null)
[ -z "$_long" ] || fail "lines over 80 columns (hard rule):
$_long"
_n=$((_n + 1))

# --- the house naming + indentation conventions, ENFORCED HERE ---------------
# The fleet conventions (shared-notes/_common.md, "Code style") are not hooked
# yet, deliberately, so that the trees can be brought into line before anything
# blocks a commit. Asserting them in the suite NOW means charon arrives already
# compliant and stays that way, and it means a violation is caught by the person
# who introduced it rather than by whoever next runs a hook.

# 1. INDENT WITH 2 SPACES, NEVER TABS.
#
# A file that legitimately CONTAINS a tab -- a captured transcript, a Makefile
# recipe -- declares so with a `tabs-are-data:` marker and says why. That is the
# honest shape for an exception: it lives in the file it applies to, it carries
# its reason, and it cannot be forgotten. A silent allowlist here would rot the
# moment the file changed.
for _f in "$HERE"/bin/* "$HERE"/libexec/* "$HERE"/setup.sh "$HERE"/test/run \
          "$HERE"/test/harness_lib "$HERE"/test/*.t; do
  [ -f "$_f" ] || continue
  grep -q "$(printf '\t')" "$_f" || continue
  head -60 "$_f" | grep -q 'tabs-are-data:' && continue
  fail "$(basename "$_f") contains a TAB and does not declare why. Indent with
    2 spaces; if the tab is DATA (a captured transcript, say), add a
    'tabs-are-data: <reason>' marker in the file's header."
done
_n=$((_n + 1))

# 2. EVERYTHING MATCHING *_lib IS SOURCED, NEVER EXECUTED.
#
# This is the assertion the naming rule exists to make possible: `_` separates a
# name from its classifier where `-` separates words, so `common_lib` parses as
# name + role and can be checked, while `common-lib` could not be told from a
# file simply called that. A shebang or an exec bit on a `_lib` means somebody
# made it runnable and the seam has quietly gone.
for _f in "$HERE"/bin/*_lib "$HERE"/libexec/*_lib "$HERE"/test/*_lib; do
  [ -f "$_f" ] || continue
  case "$(head -1 "$_f")" in
    '#!'*) fail "$(basename "$_f") is named *_lib (sourced) but has a SHEBANG,
      so it claims to be executable. Either drop the shebang or drop the
      marker -- the name has to tell the truth about how it is loaded." ;;
  esac
  [ -x "$_f" ] && fail "$(basename "$_f") is named *_lib (sourced) but is
    EXECUTABLE. The marker is what makes the seam checkable; an exec bit on it
    is a lie."
  _n=$((_n + 1))
done

# 3. AN EXECUTED FILE TAKES A BARE NAME, not a language tag.
#
# `foo.py` rewritten in Rust breaks every caller for no reason; `foo` does not.
# setup.sh is EXEMPT and frozen: it is this fleet's package contract and tackup
# branches on the name, so renaming it would break the caller this rule exists
# to protect.
for _f in "$HERE"/bin/* "$HERE"/libexec/* "$HERE"/test/run; do
  [ -f "$_f" ] || continue
  case "$(head -1 "$_f")" in '#!'*) ;; *) continue ;; esac
  case "$(basename "$_f")" in
    setup.sh) continue ;;
    *.sh|*.bash|*.py|*.pl) fail "$(basename "$_f") is EXECUTED but carries a
      language suffix. An executed file takes a bare name so that rewriting it
      in another language does not break its callers." ;;
  esac
  _n=$((_n + 1))
done

pass "$_n checks: parse, lint, 80 columns, tabs, *_lib seam, bare names"
