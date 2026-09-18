# test/lib.sh - harness for charon's shell tests (test/*.t), sourced by each.
#
# Call `harness_init <name>`: sets HERE (the repo root, so a test reaches bin/ +
# setup.sh), a private scratch dir T (removed on exit), and the pass/fail
# helpers. Everything a test touches is confined to T; nothing outside it is
# written. POSIX sh; run one with `sh test/<name>.t`, all with test/run.
harness_init() {   # <name>
  TEST_NAME=$1
  HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT INT TERM
}
pass() { printf 'ok   %s%s\n' "$TEST_NAME" "${1:+ ($1)}"; }
fail() { printf 'FAIL %s: %s\n' "$TEST_NAME" "$1" >&2; exit 1; }
skip() { printf 'skip %s (%s)\n' "$TEST_NAME" "$1"; exit 0; }

# A PATH that mirrors the system bins but OMITS <tool>, printed on stdout.
#
# REMOVING A STUB DOES NOT SIMULATE AN ABSENT TOOL, and this project has been
# caught by that twice: once asserting a systemd-free box while
# /usr/bin/systemctl was still on PATH, and once "testing" an absent
# systemd-inhibit that was really the REAL one being GRANTED by a seated
# session. Both tests passed while asserting the opposite of their claim.
#
# It also refuses to return a PATH that fails the OTHER way -- an empty PATH
# would make the case die on a missing grep before reaching the code under
# test. So: mirror what a test plausibly needs, minus the one tool, and FAIL
# LOUDLY here if the tool is still reachable or was never there to begin with.
path_without() {   # <tool> [extra-tools-to-mirror...]
  _pw_tool=$1; shift
  command -v "$_pw_tool" >/dev/null 2>&1 \
    || fail "path_without $_pw_tool: it is not on PATH at all, so a test
    asserting its absence would pass for the wrong reason"
  _pw_dir=$T/.path_without_$_pw_tool
  mkdir -p "$_pw_dir"
  for _pw_t in grep sed cat head printf ls rm mkdir chmod env sh awk "$@"; do
    _pw_p=$(command -v "$_pw_t" 2>/dev/null) || continue
    # ONLY an absolute path. `command -v printf` answers "printf" for a shell
    # BUILTIN, and linking that made a dangling relative symlink -- harmless
    # (the builtin still wins) but it is exactly the kind of junk that makes a
    # later -e test lie, since -e is FALSE for a dangling link.
    case "$_pw_p" in /*) ln -sfn "$_pw_p" "$_pw_dir/$_pw_t" ;; esac
  done
  ( PATH=$_pw_dir; export PATH
    command -v "$_pw_tool" >/dev/null 2>&1 ) \
    && fail "path_without $_pw_tool: still reachable in the mirrored PATH"
  printf '%s' "$_pw_dir"
}
