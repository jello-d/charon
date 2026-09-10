#!/bin/sh
# setup.sh - install / uninstall / check / test / bootstrap the charon
# remote-storage sync suite. The SINGLE entry point a consumer or provisioning
# layer uses.
#
# The tools, in bin/:
#   charon-mount   mount an rclone remote via FUSE + its systemd --user unit
#   charon-sync    keep a local cache in step with the mount (unison), driven by
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
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    if command -v "$_n" >/dev/null 2>&1; then ok "$_n present"
    else bad "$_n not on PATH"; fi; done
  [ -f "$_lib/$PKG/common.sh" ] && ok "libexec/common.sh installed" \
    || bad "libexec/common.sh missing ($_lib/$PKG/common.sh)"
  [ -f "$_shr/$PKG/example.conf" ] && ok "share example.conf installed" \
    || bad "share/example.conf missing ($_shr/$PKG/example.conf)"
  for _d in $DEPS_HARD; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent (core: mount/sync will not work)"; done
  for _d in $DEPS_SOFT; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent (a feature degrades)"; done
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
