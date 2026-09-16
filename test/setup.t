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

# --- and it must FAIL on a BROKEN install, which nothing asserted until now ---
# A check only ever run against a healthy tree proves nothing: this one exited
# 0 on every breakage below until 2026-09-16, because `command -v <name>` was
# satisfied by ANY copy on PATH.
_chk() { PATH="$1" sh "$HERE/setup.sh" check >"$T/c.out" 2>&1; }

# SHADOWED: a different charon earlier on PATH. The conventions ban two copies
# on PATH precisely because the stale one wins and then rots unnoticed, so the
# check has to assert WHICH copy resolves, not merely that one does.
mkdir -p "$T/shadow"
printf '#!/bin/sh\nexit 0\n' > "$T/shadow/charon"; chmod +x "$T/shadow/charon"
_chk "$T/shadow:$XDG_BIN_HOME:$PATH" \
  && fail "check passed while a DIFFERENT charon shadowed the install"
grep -qi 'shadow' "$T/c.out" \
  || fail "check did not explain that the command was shadowed"
rm -rf "$T/shadow"

# MISSING: the installed command deleted out from under it.
mv "$XDG_BIN_HOME/charon" "$T/charon.parked"
_chk "$XDG_BIN_HOME:$PATH" && fail "check passed with the command uninstalled"
mv "$T/charon.parked" "$XDG_BIN_HOME/charon"

# DANGLING: the symlink survives but its target does not.
ln -sfn /nonexistent/charon "$XDG_BIN_HOME/charon"
_chk "$XDG_BIN_HOME:$PATH" && fail "check passed on a DANGLING symlink"
sh "$HERE/setup.sh" install >/dev/null || fail "reinstall after breakage failed"
_chk "$XDG_BIN_HOME:$PATH" || fail "check did not go green again after repair"

# bootstrap seeds the example into an empty profiles.d, and is a no-op once full
sh "$HERE/setup.sh" bootstrap >/dev/null || fail "bootstrap errored"
[ -f "$XDG_CONFIG_HOME/charon/profiles.d/example.conf" ] \
  || fail "bootstrap did not seed the example profile"
grep -q '^SOURCE=' "$XDG_CONFIG_HOME/charon/profiles.d/example.conf" \
  || fail "seeded example does not name a SOURCE"
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
