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
# would make a case die on a missing dirname before reaching the code under
# test. So: mirror the bin dirs WHOLESALE minus the named tools, and FAIL
# LOUDLY if any is still reachable, or was never there to begin with.
path_without() {   # <tool>... -> a PATH dir missing ALL of them
  for _pw_t in "$@"; do
    command -v "$_pw_t" >/dev/null 2>&1 \
      || fail "path_without $_pw_t: it is not on PATH at all, so a test
      asserting its absence would pass for the wrong reason"
  done
  _pw_tool=$1
  _pw_dir=$T/.path_without_$_pw_tool
  mkdir -p "$_pw_dir"
  # MIRROR THE BIN DIRS WHOLESALE, minus the one tool. A hand-listed set of
  # "tools a test probably needs" is whack-a-mole: the first version missed
  # dirname, which bin/charon needs to self-locate, so the case died on a
  # missing dirname instead of exercising the absent-tool path. Anything that
  # runs a real charon command needs far more than a curated list.
  for _pw_d in /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$_pw_d" ] || continue
    for _pw_f in "$_pw_d"/*; do
      [ -e "$_pw_f" ] || continue
      _pw_b=${_pw_f##*/}
      _pw_skip=
      for _pw_t in "$@"; do [ "$_pw_b" = "$_pw_t" ] && _pw_skip=y; done
      [ -n "$_pw_skip" ] && continue
      [ -e "$_pw_dir/$_pw_b" ] || ln -sfn "$_pw_f" "$_pw_dir/$_pw_b"
    done
  done
  # Assert honesty on the FILESYSTEM, not via `command -v` in a subshell: an
  # assertion about PATH resolution is subject to the same export and
  # command-hashing subtleties it is trying to test, and the first version of
  # this check silently never fired because of them. -L as well as -e, because
  # -e FOLLOWS a symlink and is FALSE for a dangling one.
  for _pw_t in "$@"; do
    { [ -L "$_pw_dir/$_pw_t" ] || [ -e "$_pw_dir/$_pw_t" ]; } \
      && fail "path_without: $_pw_t is still present in the mirrored PATH"
  done
  printf '%s' "$_pw_dir"
}
