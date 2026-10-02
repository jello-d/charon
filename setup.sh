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
#   ./setup.sh install     COPY charon into its payload tree + link bin and man
#   ./setup.sh bootstrap   copy the example profile into an EMPTY profiles.d
#   ./setup.sh uninstall   remove the links and the payload
#   ./setup.sh check       tools + deps present; [OK]/[FAIL] markers
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. Honors PREFIX (default ~/.local) + XDG_* so a test
# sandboxes it. The mount/sync systemd --user units are installed by the tools'
# own `install` verbs (charon-mount install / charon-sync install), not here.
#
# AN INSTALL IS A COPY, NOT A LINK INTO THIS TREE (converted 2026-10-02 to the
# fleet's place-not-link rule). It used to symlink ~/.local/{bin,libexec,share,
# man} straight at this directory, which is fine for a checkout and broken for
# the way charon actually ships: an integrator clones it to a CACHE
# (~/.cache/<layer>/pkgs/charon) that is re-cloned on every sweep and wiped on
# demand, so every one of those links dangles and the command simply stops
# existing. A copy cannot.
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
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
# THE PAYLOAD: one tree holding charon exactly as shipped, with bin/, libexec/,
# share/ and man/ INSIDE it as siblings. That nesting is not a wart to tidy: an
# installed `charon` resolves its own real path and reads ../libexec and
# ../share/charon relative to it, so the three must stay siblings or the
# command resolves into an empty tree. The same invariant is what makes a
# checkout, a relocated prefix and this payload all work from one code path.
_pay=$_shr/$PKG
# THE RETIRED ROOT, named once so install, uninstall and check all remove or
# report the same path instead of each spelling it. A LAYOUT SWITCH MUST REMOVE
# THE LAYOUT IT REPLACES: a surviving ~/.local/libexec/charon pointing into a
# clone is a second copy of every impl, and the one thing worse than a dangling
# link is a stale one that still resolves.
_oldlib=$PREFIX/libexec/$PKG
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

_ln() { mkdir -p "$(dirname -- "$2")"; ln -sfn "$1" "$2"; }

# _rmln <link> <acceptable-target>...: remove the link only if it is OURS.
# TWO acceptable targets during the layout switch, because a box that has not
# reinstalled since the conversion still carries a link at the SOURCE tree, and
# an uninstall that leaves it behind leaves a dangling `charon` on PATH, which
# is the failure this whole change is about.
_rmln() {
  _rl=$1; shift
  _rc_cur=$(readlink "$_rl" 2>/dev/null) || return 0
  for _rt in "$@"; do
    if [ "$_rc_cur" = "$_rt" ]; then rm -f "$_rl"; return 0; fi
  done
  return 0
}

# _payload_stage: build the new payload BESIDE the live one and swap it in.
#
# STAGED AND SWAPPED, never emptied in place, because a timer may fire a sync
# at any moment and an install that removed the payload first would make
# `charon sync <profile>` fail for the length of a copy. Two renames is as
# close to atomic as a directory gets.
#
# NO VENV TO CARRY ACROSS, and that is worth stating rather than leaving to be
# rediscovered: charon is POSIX sh end to end, with rclone and unison as
# external binaries, so there is nothing inside the payload that an install
# cannot rebuild from the source tree. The fleet's conversion recipe lists
# charon under its venv tier; that is a misfiling. Anything generated at run
# time (traits, failure records) lives in ~/.local/state/charon, and the config
# in ~/.config/charon, both deliberately OUTSIDE the payload, so a restage can
# never take state with it.
_payload_stage() {
  _ps_new=$_pay.new
  _ps_old=$_pay.old
  # Expanded and CHECKED before anything is removed, per the standing rule
  # that `rm -rf` never runs on an unexamined variable: an empty or short
  # $_pay here would delete whatever that resolves to.
  case $_pay in
  /*/*) ;;
  *) bad "refusing to stage a payload at '$_pay'"; return 1 ;;
  esac
  rm -rf -- "$_ps_new" "$_ps_old"
  mkdir -p "$_ps_new" || { bad "could not create $_ps_new"; return 1; }
  for _d in bin libexec share man; do
    [ -d "$_root/$_d" ] || continue
    cp -R "$_root/$_d" "$_ps_new/" || { bad "could not copy $_d"; return 1; }
  done
  # The payload is only useful if the command and what it self-locates are all
  # in it, so assert that before anything is swapped: a half-copied tree must
  # fail here, where the live install is still untouched.
  for _f in bin/$PKG libexec/common_lib share/$PKG/example.conf; do
    [ -f "$_ps_new/$_f" ] && continue
    bad "staged payload has no $_f"; rm -rf -- "$_ps_new"; return 1
  done
  if [ -e "$_pay" ] || [ -L "$_pay" ]; then
    mv -- "$_pay" "$_ps_old" \
      || { bad "could not move the old payload aside"; return 1; }
  fi
  mv -- "$_ps_new" "$_pay" || { bad "could not swap in the new payload"
    [ -e "$_ps_old" ] && mv -- "$_ps_old" "$_pay"
    return 1; }
  rm -rf -- "$_ps_old"
}

# _retire_old_layout: remove the symlink-era ~/.local/libexec/<pkg>. Shape
# guarded for the same reason as the payload, and the directory above it is
# removed only when it empties, since it may hold another package's.
_retire_old_layout() {
  [ -e "$_oldlib" ] || [ -L "$_oldlib" ] || return 0
  case $_oldlib in
  /*/libexec/?*) ;;
  *) warn "not retiring '$_oldlib': unexpected shape"; return 0 ;;
  esac
  rm -rf -- "$_oldlib"
  rmdir "$PREFIX/libexec" 2>/dev/null || :
  echo "$PKG: retired the old layout at $_oldlib"
}

do_install() {
  # NOTHING IS CREATED BEFORE THE STAGE'S SHAPE GUARD HAS RUN. A `mkdir -p
  # "$_bin" "$_shr"` used to open this function, so a refused payload path
  # still left empty directories behind at whatever that path resolved to,
  # which is a small mess and a confusing one: the install says it refused and
  # the tree says it started. The stage and _ln each create what they need.
  _payload_stage || return 1
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    _ln "$_pay/bin/$_n" "$_bin/$_n"; done
  _man_pages | while IFS= read -r _m; do
    _rel=${_m#"$_root"/}
    _ln "$_pay/$_rel" "$_man/${_rel#man/}"; done
  _retire_old_layout
  echo "$PKG: installed to $_pay (+ bin and man links in $PREFIX)"
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
  echo "$PKG: seeded $PROFILES_DIR/example.conf; edit it, then charon-sync"\
       "install"
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    _rmln "$_bin/$_n" "$_pay/bin/$_n" "$_t"; done
  _man_pages | while IFS= read -r _m; do
    _rel=${_m#"$_root"/}
    _rmln "$_man/${_rel#man/}" "$_pay/$_rel" "$_m"; done
  # The pre-conversion share link lived at the path the payload now occupies,
  # so a box that never reinstalled has a SYMLINK there and the rm below must
  # not follow it. Remove it as a link first, then treat what is left as a
  # directory.
  _rmln "$_pay" "$_root/share/$PKG"
  _retire_old_layout
  if [ -L "$_pay" ]; then
    warn "$_pay is a symlink this install did not create; leaving it"
  elif [ -d "$_pay" ]; then
    case $_pay in
    /*/*) rm -rf -- "$_pay" ;;
    *) bad "refusing to remove a payload at '$_pay'" ;;
    esac
  fi
  echo "$PKG: removed $_pay and its links from $PREFIX"
}

# check_payload: the three questions the layout switch added, and the third is
# the one with teeth.
#
# A SELF-CONTAINED TREE is not provable by listing what exists, because the old
# layout put something at every one of those paths too. What distinguishes the
# two is DIRECTION: under the old layout a path under $PREFIX resolved back into
# this source tree, and under the new one nothing does. So the assertion is on
# the absence of a link INTO $_root, which is a fact about the whole prefix and
# cannot be satisfied by a stale artifact the way a presence check can.
#
# $_root is the right thing to compare against whichever tree this is run from:
# a cache clone (where a surviving link is the dangling-on-wipe bug) or a
# checkout (where it is the same bug, waiting for a branch switch).
check_payload() {
  if [ -L "$_pay" ]; then
    bad "$_pay is a SYMLINK: this install still depends on a source tree"
  elif [ ! -d "$_pay" ]; then
    bad "no payload tree at $_pay: reinstall $PKG"
  else
    _cpr=0
    for _f in bin/$PKG libexec/common_lib share/$PKG/example.conf \
              share/$PKG/example-source.conf; do
      if [ -f "$_pay/$_f" ] && [ ! -L "$_pay/$_f" ]; then continue; fi
      bad "payload is missing $_f (or it is a link): $_pay/$_f"; _cpr=1
    done
    if [ "$_cpr" = 0 ]; then ok "payload is a self-contained tree ($_pay)"; fi
  fi
  # Each installed link must point INTO the payload, not at this tree. No
  # pipeline here, deliberately: `bad` raises RC, and a `while` on the right of
  # a pipe runs in a SUBSHELL where that assignment cannot escape, which is
  # this project's recurring shape for a check that prints [FAIL] and exits 0.
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    _cpg=$(readlink "$_bin/$_n" 2>/dev/null) || _cpg=
    if [ "$_cpg" = "$_pay/bin/$_n" ]; then
      ok "bin/$_n links into the payload"
    else
      bad "bin/$_n does not link to $_pay/bin/$_n (got '$_cpg')"
    fi; done
  for _m in "$_root"/man/man*/*.[0-9]; do
    [ -e "$_m" ] || continue
    _rel=${_m#"$_root"/}; _rel=${_rel#man/}
    _cpg=$(readlink "$_man/$_rel" 2>/dev/null) || _cpg=
    if [ "$_cpg" = "$_pay/man/$_rel" ]; then
      ok "man/$_rel links into the payload"
    else
      bad "man/$_rel does not link to $_pay/man/$_rel (got '$_cpg')"
    fi; done
  # NOTHING under the installed prefix may resolve back into this source tree.
  # One walk of all three roots, measured at 0.05s over a real ~/.local, which
  # is why it is affordable to ask the BROAD question rather than only
  # re-checking the paths this script just wrote: the point of the question is
  # the artifact nobody remembered.
  _stray=$(find "$PREFIX" "$_bin" "$_shr" -type l 2>/dev/null | sort -u \
    | while IFS= read -r _l; do
        case "$(readlink -m -- "$_l" 2>/dev/null)" in
          "$_root"|"$_root"/*) printf '%s\n' "$_l" ;;
        esac; done)
  if [ -n "$_stray" ]; then
    bad "$(printf '%s\n' "$_stray" | wc -l | tr -d ' ') link(s) resolve into\
 $_root, so the next re-clone or cache wipe breaks them:"
    printf '%s\n' "$_stray" | sed 's/^/           /'
  else
    ok "no link under $PREFIX resolves into this source tree"
  fi
  if [ -e "$_oldlib" ] || [ -L "$_oldlib" ]; then
    warn "retired layout path survives: $_oldlib (reinstall removes it)"
  else
    ok "no retired layout path"
  fi
}

do_check() {
  echo "== $PKG (rclone mount + unison sync) =="
  # THREE questions, not one. `command -v` alone answers only "is something
  # called this on PATH", which a DIFFERENT copy satisfies just as well as the
  # install being audited: a stale /usr/local/bin/charon, or the pkg clone's,
  # would report [OK] while this install rotted behind it. That shadowing is
  # the failure the conventions ban outright, so assert against it here:
  # installed at all, reachable, and the reachable one is THIS one.
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    _want=$_bin/$_n
    _got=$(command -v "$_n" 2>/dev/null || true)
    if [ ! -e "$_want" ]; then
      bad "$_n not installed ($_want)"
    elif [ -z "$_got" ]; then
      # WARN, not bad: whether $_bin is on the CALLER'S PATH is the caller's
      # business, not this package's. We installed it where we said we would,
      # which is the part we control and the part already asserted above.
      #
      # Reporting it as a failure is wrong in both directions. A standalone
      # user with a short PATH gets told, which is useful, but their install is
      # not broken. And an INTEGRATOR running this check from a non-login
      # context (an ssh command, a cron, an agent) has no ~/.local/bin on PATH
      # by construction, so a hard failure there is a false finding it cannot
      # clear, observed 2026-09-24, where a remote `tackup check` reported
      # this against a box whose own provision had just verified clean.
      warn "$_n installed at $_want but not on THIS shell's PATH"
    elif [ "$(readlink -f "$_got" 2>/dev/null)" \
         != "$(readlink -f "$_want" 2>/dev/null)" ]; then
      bad "$_n on PATH is $_got, NOT the installed $_want (shadowed)"
    else ok "$_n present, and PATH resolves to this install"; fi; done
  check_payload
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
