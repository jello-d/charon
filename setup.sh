#!/bin/sh
# setup.sh - install / uninstall / check / test / bootstrap the charon
# remote-storage sync suite. The SINGLE entry point a consumer or provisioning
# layer uses.
#
# One command, bin/charon, dispatching to the mount / sync impls in libexec/:
#   charon mount   mount an rclone remote via FUSE + its systemd --user unit
#   charon sync    keep a local cache in step with the mount (unison), driven by
#                  per-subtree profiles in ~/.config/charon/profiles.d/*.conf
#
#   ./setup.sh install     symlink the tools (+ libexec/share/man) into ~/.local
#   ./setup.sh bootstrap   copy the example profile into an EMPTY profiles.d
#   ./setup.sh uninstall   remove the symlinks
#   ./setup.sh check       tools + deps present; [OK]/[FAIL] markers
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. Honors PREFIX (default ~/.local) + XDG_* so a test
# sandboxes it. The mount/sync systemd --user units are installed by the tools'
# own `install` verbs (charon-mount install / charon-sync install), not here.
set -eu

PKG=charon
VERSION=0.1.0
# shellcheck disable=SC1007  # CDPATH= is a deliberate clear, not a typo
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -z "${HOME:-}" ]; then
  HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  if [ -z "$HOME" ]; then
    echo "$PKG: HOME unset and not derivable from passwd" >&2; exit 1
  fi
  export HOME
fi

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_lib=$PREFIX/libexec
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}
PROFILES_DIR=$_cfg/charon/profiles.d
# External runtime deps: HARD (core) vs SOFT (a feature degrades).
DEPS_HARD="rclone unison"
DEPS_SOFT="fusermount3 systemctl"
RC=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[32m'); _R=$(printf '\033[31m')
  _Y=$(printf '\033[33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

do_install() {
  mkdir -p "$_bin" "$_lib" "$_shr"
  for _t in "$_root"/bin/*; do ln -sfn "$_t" "$_bin/$(basename "$_t")"; done
  ln -sfn "$_root/libexec" "$_lib/$PKG"
  ln -sfn "$_root/share/$PKG" "$_shr/$PKG"
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    mkdir -p "$_d"; ln -sfn "$_m" "$_d/$(basename "$_m")"; done
  echo "$PKG: linked the tools (+ libexec, share, man) into $PREFIX"
}

do_bootstrap() {
  _ex=$_root/share/$PKG/example.conf
  if [ -d "$PROFILES_DIR" ] && [ -n "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]
  then
    echo "$PKG: $PROFILES_DIR already has profiles; leaving them"
    return 0
  fi
  mkdir -p "$PROFILES_DIR"
  cp "$_ex" "$PROFILES_DIR/example.conf"
  echo "$PKG: seeded $PROFILES_DIR/example.conf -- edit it, then charon-sync"\
       "install"
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _l=$_bin/$(basename "$_t")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_t" ] && rm -f "$_l" || :; done
  [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec" ] \
    && rm -f "$_lib/$PKG" || :
  [ "$(readlink "$_shr/$PKG" 2>/dev/null)" = "$_root/share/$PKG" ] \
    && rm -f "$_shr/$PKG" || :
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_m" ] && rm -f "$_l" || :; done
  echo "$PKG: removed the ~/.local symlinks"
}

do_check() {
  echo "== $PKG (rclone mount + unison sync) =="
  # THREE questions, not one. `command -v` alone answers only "is something
  # called this on PATH", which a DIFFERENT copy satisfies just as well as the
  # install being audited: a stale /usr/local/bin/charon, or the pkg clone's,
  # would report [OK] while this install rotted behind it. That shadowing is
  # the failure the conventions ban outright, so assert against it here --
  # installed at all, reachable, and the reachable one is THIS one.
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    _want=$_bin/$_n
    _got=$(command -v "$_n" 2>/dev/null || true)
    if [ ! -e "$_want" ]; then
      bad "$_n not installed ($_want)"
    elif [ -z "$_got" ]; then
      bad "$_n installed at $_want but NOT on PATH"
    elif [ "$(readlink -f "$_got" 2>/dev/null)" \
         != "$(readlink -f "$_want" 2>/dev/null)" ]; then
      bad "$_n on PATH is $_got, NOT the installed $_want (shadowed)"
    else ok "$_n present, and PATH resolves to this install"; fi; done
  if [ -f "$_lib/$PKG/common.sh" ]; then ok "libexec/common.sh installed"
  else bad "libexec/common.sh missing ($_lib/$PKG/common.sh)"; fi
  if [ -f "$_shr/$PKG/example.conf" ]; then ok "share example.conf installed"
  else bad "share/example.conf missing ($_shr/$PKG/example.conf)"; fi
  if [ -f "$_shr/$PKG/example-source.conf" ]; then
    ok "share example-source.conf installed"
  else bad "share/example-source.conf missing"; fi
  for _d in $DEPS_HARD; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else warn "dep $_d absent (core: mount/sync will not work)"; fi
  done
  for _d in $DEPS_SOFT; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else warn "dep $_d absent (a feature degrades)"; fi
  done
}

_U="usage: setup.sh [install|bootstrap|uninstall|check|test|version]"
case "${1:-install}" in
  install)   do_install ;;
  bootstrap) do_bootstrap ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
