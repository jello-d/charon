#!/bin/sh
# setup.t - the install roundtrip against a scratch PREFIX: install -> assert
# the ~/.local symlinks (bin, libexec, share, man) land -> check -> bootstrap
# into an empty profiles.d -> uninstall -> assert gone. Confined to the scratch.
. "$(dirname "$0")/lib.sh"
harness_init setup

PREFIX=$T/local
XDG_BIN_HOME=$PREFIX/bin
XDG_DATA_HOME=$PREFIX/share
XDG_CONFIG_HOME=$T/config
export PREFIX XDG_BIN_HOME XDG_DATA_HOME XDG_CONFIG_HOME

sh "$HERE/setup.sh" install >/dev/null || fail "install errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t"); _l=$XDG_BIN_HOME/$_n
  [ -L "$_l" ] && [ "$(readlink "$_l")" = "$_t" ] \
    || fail "$_n not linked into PREFIX/bin"
done
[ -L "$PREFIX/libexec/charon" ] || fail "libexec/charon not linked"
[ -f "$PREFIX/libexec/charon/common.sh" ] || fail "common.sh not reachable"
[ -L "$XDG_DATA_HOME/charon" ] || fail "share/charon not linked"
[ -e "$XDG_DATA_HOME/man/man1/charon.1" ] || fail "man page not installed"

# check reports the tools (put the sandbox bin FIRST so command -v resolves it)
PATH="$XDG_BIN_HOME:$PATH" sh "$HERE/setup.sh" check >"$T/check.out" 2>&1 \
  || true
grep -q '\[OK\].*charon present' "$T/check.out" \
  || fail "check did not report the linked command"

# bootstrap seeds the example into an empty profiles.d, and is a no-op once full
sh "$HERE/setup.sh" bootstrap >/dev/null || fail "bootstrap errored"
[ -f "$XDG_CONFIG_HOME/charon/profiles.d/example.conf" ] \
  || fail "bootstrap did not seed the example profile"
grep -q '^SUBTREE=' "$XDG_CONFIG_HOME/charon/profiles.d/example.conf" \
  || fail "seeded example missing SUBTREE"
printf 'SUBTREE=Keep\n' > "$XDG_CONFIG_HOME/charon/profiles.d/mine.conf"
sh "$HERE/setup.sh" bootstrap >/dev/null || fail "second bootstrap errored"
grep -q '^SUBTREE=Keep' "$XDG_CONFIG_HOME/charon/profiles.d/mine.conf" \
  || fail "bootstrap clobbered an existing profile"

sh "$HERE/setup.sh" uninstall >/dev/null || fail "uninstall errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  [ -e "$XDG_BIN_HOME/$_n" ] && fail "$_n still present after uninstall" || :
done
[ -e "$PREFIX/libexec/charon" ] && fail "libexec link not removed" || :

pass "install/check/bootstrap/uninstall roundtrip"
