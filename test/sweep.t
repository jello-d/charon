#!/bin/sh
# sweep.t - orphaned unison transfer temps: the mechanism, and the sweeper.
#
# THE GAP THIS CLOSES. charon has carried `ignore = Name .unison.*.unison.tmp`
# since 2026-09-11 with a comment saying sweeping the litter "is an out-of-band
# job" -- and that job did not exist. Worse, the reason crumbs accumulate was
# never established, so the ignore itself was under suspicion for blocking
# unison's cleanup. This test settles the mechanism with REAL unison over REAL
# trees (a prf-line test could never have), then pins the sweeper built on it.
#
# The four facts, each measured rather than reasoned:
#   1. the temp is written on the DESTINATION side -- so it cannot be kept off
#      a remote replica, because that is where a remote-bound file is staged.
#   2. unison DELETES its own temp when it next propagates that path.
#   3. it does so WITH the ignore set too, so the ignore is NOT the culprit.
#   4. a temp orphans ONLY when the path stops needing propagation while one is
#      outstanding -- the wedged-profile signature, and the whole of the
#      2026-09-24 incident.
#
# Fact 3 is the one worth having in a suite forever: it is the difference
# between "our config is causing this" and "this is inherent", and getting it
# wrong sends someone to remove an ignore that is load-bearing.
. "$(dirname "$0")/lib.sh"
harness_init sweep

command -v unison >/dev/null 2>&1 || skip "unison not installed"

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_TRAITS_DIR=$T/st
export UNISON_DIR=$T/uni
CFG=$T/cfg
mkdir -p "$CFG/profiles.d" "$CFG/sources.d" "$T/st" "$T/uni" "$T/.cache" \
         "$T/bin"

# ---------------------------------------------------------------- part 1 ----
# The mechanism, with real unison. No charon involved yet: if these assertions
# ever change it is unison's behaviour that moved, and the sweeper's whole
# justification moves with it.
L=$T/repL R=$T/repR UD=$T/u1
mkdir -p "$L" "$R" "$UD"
# Big enough that a transfer can be caught in flight. Zeros are fine: the
# question is timing, not content. Kept modest because the harness scratch dir
# is usually a tmpfs, so this is RAM, twice over (both replicas).
dd if=/dev/zero of="$L/big.bin" bs=1M count=300 status=none 2>/dev/null \
  || fail "could not create the test payload"

_uni() { UNISON=$UD unison "$L" "$R" -batch -times "$@"; }

# The crumbs in a directory, via pathname expansion rather than `ls | grep`.
# FORK-FREE ON PURPOSE: _strand below has to win a race against a local copy
# running at tmpfs speed, and a poll loop that forks two processes per iteration
# is orders of magnitude too slow to see the window reliably. A flaky strand
# would make this whole file a test that sometimes cannot fail.
_crumbs_in() {   # <dir>
  set -- "$1"/.unison.*.unison.tmp
  [ -e "$1" ] || return 0
  for _c; do printf '%s\n' "$_c"; done
}

# Strand a temp: kill unison the instant one materialises on the destination.
_strand() {
  rm -rf "$R" "$UD"; mkdir -p "$R" "$UD"
  _uni >/dev/null 2>&1 &
  _sp=$!
  while :; do
    set -- "$R"/.unison.*.unison.tmp
    if [ -e "$1" ]; then
      kill -9 "$_sp" 2>/dev/null || :
      wait "$_sp" 2>/dev/null || :
      return 0
    fi
    kill -0 "$_sp" 2>/dev/null || { wait "$_sp" 2>/dev/null || :; return 1; }
  done
}

_strand || fail "could not strand a temp mid-transfer: unison finished the
  600 MiB copy before the watcher saw a temp, so parts 1a-1c cannot run"

# 1a. THE TEMP IS ON THE DESTINATION SIDE. This is why it cannot be relocated:
# for a cache -> remote propagation the destination IS the remote.
[ -n "$(_crumbs_in "$R")" ] \
  || fail "no temp on the DESTINATION side after an interrupted transfer"
[ -z "$(_crumbs_in "$L")" ] \
  || fail "a temp appeared on the SOURCE side, which contradicts the premise
  that temps are staged in the destination directory"

# 1b. UNISON CONSUMES ITS OWN TEMP when it next propagates that path.
_uni >/dev/null 2>&1 || fail "the follow-up unison run failed"
[ -z "$(_crumbs_in "$R")" ] \
  || fail "unison did NOT clean up its own temp after a successful
  propagation: $(_crumbs_in "$R")"
[ -f "$R/big.bin" ] || fail "the follow-up run did not deliver the real file"

# 1c. ...AND IT STILL DOES SO WITH THE TIER 0 IGNORE SET. The ignore was a
# standing suspect for the litter; this is the assertion that clears it. If
# this ever fails, the ignore really is blocking cleanup and the comment in
# prf:charon is wrong.
_strand || fail "could not strand a temp for the ignore case"
_uni -ignore "Name $(printf '.unison.*.unison.tmp')" >/dev/null 2>&1 \
  || fail "the follow-up run failed with the ignore set"
[ -z "$(_crumbs_in "$R")" ] \
  || fail "WITH the Tier 0 ignore set, unison left its own temp behind:
  $(_crumbs_in "$R") -- the ignore IS blocking cleanup, which would make the
  sweeper's rationale (and prf:charon's comment) wrong"

# 1d. THE ORPHANING CONDITION: the path stops needing propagation while a temp
# is outstanding. This is the ONLY way a crumb becomes permanent, and it is
# exactly what a wedged profile manufactures.
_strand || fail "could not strand a temp for the orphan case"
_orphan=$(_crumbs_in "$R")
cp -p "$L/big.bin" "$R/big.bin"          # make the replicas agree out of band
_out=$(_uni -ignore "Name .unison.*.unison.tmp" 2>&1) || :
case $_out in
  *"Nothing to do"*) : ;;
  *) fail "expected unison to report nothing to do once the replicas agree,
     so that the orphaning condition is the one under test; got: $_out" ;;
esac
[ "$(_crumbs_in "$R")" = "$_orphan" ] \
  || fail "the orphan case did not reproduce: with nothing left to propagate
  the temp should survive forever, but it is gone"

# ---------------------------------------------------------------- part 2 ----
# The sweeper. Sourced directly so each guarantee can be provoked cheaply.
cat > "$T/st/gd" <<'EOF'
PROBED=2026-01-01T00:00:00+00:00
WRITABLE=yes
CASE=sensitive
TIMES=settable
PERMS=none
LINKS=no
FSTYPE=fuseblk
EOF
cat > "$CFG/sources.d/gd.conf" <<EOF
PROVIDER=rclone
REMOTE=gd
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=gd:Media\n' > "$CFG/profiles.d/media.conf"
mkdir -p "$T/mnt/Media/sub" "$T/cache/Media"

# A name WITH A SPACE, because these are filenames and this project has already
# been bitten by `for x in $(...)`: a space-containing profile name became two
# phantom timers. The same hazard applies to every crumb path, and this Drive is
# full of names like "Fenix Binary Circuit Watchface - tuned.psp".
_sub=$T/mnt/Media/sub
OLD_M="$_sub/.unison.Fenix Watchface - tuned.psp.abc123.unison.tmp"
OLD_C="$T/cache/Media/.unison.My Doc.def456.unison.tmp"
NEW_M="$T/mnt/Media/.unison.fresh transfer.999aaa.unison.tmp"
REAL="$T/mnt/Media/Fenix Binary Watchface - tuned.psp"
printf 'aaaa' > "$OLD_M"; printf 'bb' > "$OLD_C"
printf 'ccc'  > "$NEW_M"; printf 'CONTENT' > "$REAL"
# Age the two old ones past the gate; leave NEW_M fresh.
touch -d '30 days ago' "$OLD_M" "$OLD_C"

CHARON_LIB_ONLY=1 . "$HERE/libexec/charon-sync"
# extract_section reads the embedded templates out of "$_self", which the script
# derives from $0 -- and $0 is THIS TEST when the script is sourced rather than
# executed. Without this, render_prf below returns 0 having emitted a prf with
# no template in it at all, and 2f would be asserting against empty output.
_self=$HERE/libexec/charon-sync

# 2a. THE TALLY IS SCOPED AND AGE-GATED. Two old crumbs, one on each replica;
# the fresh one is a possible live resume point and must be invisible here.
# The split is the POINT: crumb_tally returns "<count> <bytes>" as one line and
# these are two integers, so word splitting is how they are read.
# shellcheck disable=SC2046
set -- $(crumb_tally)
[ "$1" = 2 ] || fail "crumb_tally counted $1, expected the 2 aged crumbs
  (the fresh one must be excluded by the age gate)"
[ "$2" = 6 ] || fail "crumb_tally totalled $2 bytes, expected 6 (4 + 2)"

# 2b. check REPORTS litter and does NOT call it drift. This is the load-bearing
# one: the 2026-09-24 incident showed that a non-zero check becomes an
# integrator's drift, and apply has no verb that clears litter -- so failing
# here would spin a provision loop forever on something harmless.
_ck=$(check_crumbs 2>&1); _ckrc=$?
[ "$_ckrc" = 0 ] || fail "check_crumbs returned $_ckrc: litter must be
  reported but must NOT be drift, or an integrator loops on it forever"
case $_ck in
  *"2 orphaned unison temp"*sweep*) : ;;
  *) fail "check_crumbs did not name the count and the remedy: $_ck" ;;
esac

# 2c. THE SWEEP REMOVES EXACTLY THE AGED CRUMBS, ON BOTH REPLICAS, AND NOTHING
# ELSE. The fresh crumb and the real file are the controls: a sweeper that
# deleted either would be deleting content.
do_sweep >/dev/null 2>&1 || fail "do_sweep returned non-zero on a clean sweep"
[ -e "$OLD_M" ] && fail "the aged crumb on the MOUNT side survived the sweep"
[ -e "$OLD_C" ] && fail "the aged crumb on the CACHE side survived the sweep"
[ -e "$NEW_M" ] || fail "the sweep deleted a FRESH temp, which may be the live
  resume point of an interrupted transfer"
[ -e "$REAL" ] || fail "the sweep deleted a real file"
[ "$(cat "$REAL")" = CONTENT ] || fail "the sweep altered a real file"

# 2d. IT IS IDEMPOTENT, and says so rather than failing.
do_sweep >/dev/null 2>&1 || fail "a second do_sweep with nothing to do failed"

# 2e. IT REFUSES TO RUN UNDER A HELD SYNC LOCK. A pass in flight owns its
# temps, and pulling a live resume point out from under it is the one way this
# verb could do harm. EX_SKIP, not a failure: the caller retries later.
#
# THE HOLDER MUST BE ANOTHER PROCESS. Holding it in this shell does not work and
# the first version of this test was fooled by it: do_sweep runs
# `exec 9>"$LOCKFILE"`, which REPLACES fd 9, closing the open file description
# the lock was attached to and releasing it. The sweep then acquired the lock it
# was supposed to be blocked by, returned 0, and deleted the crumb.
mkdir -p "$LOCKDIR"
LOCKED="$T/mnt/Media/.unison.locked case.777bbb.unison.tmp"
printf 'x' > "$LOCKED"; touch -d '30 days ago' "$LOCKED"
# THE HOLDER IS RELEASED BY A FLAG, NOT BY A KILL, and the release is ASSERTED.
# Killing it is not enough and quietly broke the case that follows: `flock -c`
# execs a shell that INHERITS the locked fd, so killing the flock process can
# leave that child alive still holding the lock. The lock was then still held
# during 2g, whose do_sweep returned EX_SKIP rather than 0 -- so 2g passed no
# matter what the code did. Caught by mutation; it is the third test in this
# project to fail this way.
flock "$LOCKFILE" -c \
  "printf held > $T/held; while [ ! -f $T/release ]; do sleep 0.05; done" &
_holder=$!
_hw=0
while [ ! -f "$T/held" ] && [ "$_hw" -lt 300 ]; do _hw=$((_hw + 1)); sleep 0.05
done
[ -f "$T/held" ] || fail "could not establish an external sync-lock holder, so
  the locked case would pass for the wrong reason"
do_sweep >/dev/null 2>&1; _lrc=$?
[ "$_lrc" = "$EX_SKIP" ] \
  || fail "do_sweep under a held lock returned '$_lrc', expected EX_SKIP
  ($EX_SKIP)"
[ -e "$LOCKED" ] \
  || fail "do_sweep deleted a crumb while the sync lock was held"
: > "$T/release"
wait "$_holder" 2>/dev/null || :
_rw=0
while [ "$_rw" -lt 300 ]; do
  flock -n "$LOCKFILE" -c true 2>/dev/null && break
  _rw=$((_rw + 1)); sleep 0.05
done
[ "$_rw" -lt 300 ] \
  || fail "the external lock holder never released the sync lock, so every
  assertion after this point would be measuring a locked-out do_sweep"
rm -f "$LOCKED"

# 2f. ONE PATTERN, TWO USERS. The glob the sweeper deletes by MUST be the glob
# the prf tells unison to ignore. If they drift, either the sweeper eats live
# content or the litter it hunts is content the reconciler still syncs.
_prf=$(render_prf media) || fail "render_prf failed in the sweep test"
case $_prf in
  *"ignore = Name $CRUMB_GLOB"*) : ;;
  *) fail "the rendered prf does not ignore CRUMB_GLOB ($CRUMB_GLOB), so the
     sweeper and the reconciler disagree about what is never content" ;;
esac
# And the rendered line is byte-identical to the literal it replaced, which is
# why parameterising it forced no reinstall anywhere.
case $_prf in
  *'ignore = Name .unison.*.unison.tmp'*) : ;;
  *) fail "parameterising the ignore changed the rendered prf, which would
     report drift on every installed box until it was re-rendered" ;;
esac

# 2g. AN UNKNOWN PROFILE IS REFUSED, not silently swept as "all". Assert on the
# LINE THAT NAMES THE REASON, never on a bare non-zero: half a dozen things in
# here can make do_sweep non-zero (a held lock did exactly that, above) and an
# exit code cannot tell you which.
_ur=$(do_sweep nosuchprofile 2>&1); _urc=$?
[ "$_urc" = 0 ] && fail "do_sweep accepted an unknown profile name"
case $_ur in
  *"unknown profile"*) : ;;
  *) fail "do_sweep rejected an unknown profile, but not for that reason
     (so the guard may be gone and something else failed): $_ur" ;;
esac

pass "unison consumes its own temps; charon sweeps only what orphans"
