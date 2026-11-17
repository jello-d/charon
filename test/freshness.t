#!/bin/sh
# freshness.t - does a change made ON THE REMOTE reach the mount?
#
# THE GAP, from manifold 2026-11-16: files sat on Drive for up to three days
# while its mount served a listing without them, rclone logged nothing, and
# every check was green. The detector writes a file straight at the remote and
# watches for it through the mount. This pins that it tells the two apart,
# heals what charon owns, records what it found, and that `check` reads it.
#
# THE FIXTURE MAKES "STALE" EXACT. A local `alias` remote has no change
# notification, so what a mount shows of a directory it has listed is decided
# by --dir-cache-time alone: 1s behaves like a mount that sees changes, 1h like
# manifold's. "The remote" is the alias's backing directory, written by a
# separate rclone process, never through the mount, which is the whole test.
#
# THE MOST IMPORTANT CASE IS THE STALE ONE, because it is the one that catches
# the mistake made by hand the same evening: a directory the mount has never
# listed is fetched fresh, so without PRIMING the cache first a stale mount
# reads as fresh. Removing the prime is a mutation this file must catch.
. "$(dirname "$0")/harness_lib"
harness_init freshness

for _need in rclone fusermount3 pgrep; do
  command -v "$_need" >/dev/null 2>&1 || skip "$_need not available"
done
[ -w /dev/fuse ] || skip "/dev/fuse is not usable here"

# Mounts and processes are cleared BEFORE the harness's delete, found from the
# kernel's table (a dead mount fails `[ -d ]`); see fuse.t for why.
_cleanup() {
  [ -s "$T/pids" ] && while read -r _p; do
    kill -KILL "$_p" 2>/dev/null; done < "$T/pids"
  awk -v d="$T/" 'index($5, d) == 1 { print $5 }' /proc/self/mountinfo \
    | while read -r _m; do fusermount3 -uz "$_m" 2>/dev/null; done
  return 0
}
_hc="'$T'"
# shellcheck disable=SC2064  # the literal is the point, see harness_lib
trap "_cleanup; rm -rf -- $_hc" EXIT
trap 'exit 130' INT     # a signal ENDS the test; see harness_lib
trap 'exit 143' TERM

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_STATE=$T/state
export CHARON_TRAITS_DIR=$T/st
export RCLONE_CONFIG=$T/rclone.conf
export CHARON_FRESH_BOUND=4
mkdir -p "$T/cfg/sources.d" "$T/state" "$T/st" "$T/src" "$T/bin"
: > "$T/pids"
cat > "$RCLONE_CONFIG" <<EOF
[loc]
type = alias
remote = $T/src
EOF

CHARON_LIB_ONLY=1 . "$HERE/libexec/charon-sync"

_mountc() {   # <name> <dir-cache-time>
  mkdir -p "$T/m-$1"
  rclone mount loc: "$T/m-$1" --dir-cache-time "$2" \
    >"$T/rclone-$1.log" 2>&1 </dev/null &
  echo $! >> "$T/pids"; echo $! > "$T/pid.$1"
  _mw=0
  until [ -n "$(mount_device "$T/m-$1")" ]; do
    sleep 0.1; _mw=$((_mw + 1))
    [ "$_mw" -lt 100 ] || fail "mount $1 never came up"
  done
}
_source() {   # <name>
  printf 'PROVIDER=rclone\nREMOTE=loc\nMOUNT=%s\nCACHE_ROOT=%s\n' \
    "$T/m-$1" "$T/cache-$1" > "$T/cfg/sources.d/$1.conf"
}
# systemctl: a RESTART of a mount unit remounts it with a SHORT cache, which
# is what a real restart does (a fresh process has nothing cached), and is
# recorded so a test can tell whether one was asked for at all.
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
for a in "\$@"; do u=\$a; done
case "\$*" in
  *restart*)
    [ -e "$T/refuse-restart" ] && exit 1
    echo "\$u" >> "$T/restarts"
    n=\${u#charon-mount@}; n=\${n%.service}
    kill -KILL "\$(cat "$T/pid.\$n")" 2>/dev/null; sleep 0.3
    fusermount3 -uz "$T/m-\$n" 2>/dev/null
    rclone mount loc: "$T/m-\$n" --dir-cache-time 1s \\
      >>"$T/rclone-\$n.log" 2>&1 </dev/null &
    echo \$! >> "$T/pids"; echo \$! > "$T/pid.\$n"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/systemctl"
PATH="$T/bin:$PATH"; export PATH

_fs() { sh "$HERE/libexec/charon-source" freshness "$@"; }
_rec() { sed -n "s/^$2=//p" "$T/state/freshness/$1" 2>/dev/null; }
_litter() { ls -A "$T/src" | grep -c '^\.charon-fresh-' || :; }
_host=$(uname -n | tr -c 'A-Za-z0-9.\n-' '_')

# ----------------------------------------------------------------- part 1 ----
# A mount that sees changes reads FRESH, and leaves nothing on the remote.
_mountc fresh 1s; _source fresh
_fs fresh >"$T/o1" 2>&1; rc=$?
[ "$rc" = 0 ] || fail "a mount that sees changes was not fresh (rc $rc): $(cat \
  "$T/o1")"
[ "$(_rec fresh RESULT)" = fresh ] || fail "fresh record says $(_rec fresh \
  RESULT)"
[ "$(_litter)" = 0 ] || fail "the freshness file was left on the remote"

# ----------------------------------------------------------------- part 2 ----
# A mount that does NOT see changes reads STALE. Freshly mounted with a long
# cache, and nothing has listed its root, so only the detector's own PRIME can
# make the cache stale; without it this would wrongly read fresh.
_mountc stale 1h; _source stale
_fs stale >"$T/o2" 2>&1; rc=$?
[ "$rc" = 1 ] || fail "a mount that does not see changes returned $rc, not 1
  (stale): $(cat "$T/o2")"
[ "$(_rec stale RESULT)" = stale ] || fail "stale record says $(_rec stale \
  RESULT)"
_rec stale DETAIL | grep -q 'not visible' \
  || fail "the stale record does not say what was not seen"
[ -e "$T/restarts" ] && fail "freshness restarted a mount without --heal" || :
[ "$(_litter)" = 0 ] || fail "a stale run left its file on the remote"

# ----------------------------------------------------------------- part 3 ----
# --heal restarts charon's mount and tests again: HEALED.
_mountc heal 1h; _source heal
_fs heal --heal >"$T/o3" 2>&1; rc=$?
[ "$rc" = 0 ] || fail "a healed mount returned $rc: $(cat "$T/o3")"
[ "$(_rec heal RESULT)" = healed ] || fail "heal record says $(_rec heal \
  RESULT): $(cat "$T/o3")"
grep -qx 'charon-mount@heal.service' "$T/restarts" \
  || fail "the heal did not restart charon-mount@heal.service"

# A refused restart stays STALE and says so.
_mountc refuse 1h; _source refuse
: > "$T/refuse-restart"
_fs refuse --heal >"$T/o4" 2>&1; rc=$?
rm -f "$T/refuse-restart"
[ "$rc" = 1 ] && [ "$(_rec refuse RESULT)" = stale ] \
  || fail "a refused restart did not leave the source stale (rc $rc)"
_rec refuse DETAIL | grep -q 'refused' \
  || fail "the record does not say the restart was refused"

# ----------------------------------------------------------------- part 4 ----
# A mount that is not there cannot be tested, and says so rather than guessing.
_source gone; mkdir -p "$T/m-gone"
_fs gone >"$T/o5" 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(_rec gone RESULT)" = untestable ] \
  || fail "an absent mount was not untestable (rc $rc, $(_rec gone RESULT))"

# ----------------------------------------------------------------- part 5 ----
# A run killed before its cleanup leaves its file; the next run clears THIS
# node's leftovers and never another node's, which may be mid-measurement.
: > "$T/src/.charon-fresh-$_host-123"
: > "$T/src/.charon-fresh-otherbox-456"
_fs fresh >/dev/null 2>&1
[ -e "$T/src/.charon-fresh-$_host-123" ] \
  && fail "this node's leftover freshness file was not cleared" || :
[ -e "$T/src/.charon-fresh-otherbox-456" ] \
  || fail "another node's freshness file was deleted"
rm -f "$T/src/.charon-fresh-otherbox-456"

# ----------------------------------------------------------------- part 6 ----
# check reads the records: fresh OK, healed WARN, stale FAULT, untestable WARN,
# never tested WARN. Driven against the records parts 1-4 wrote.
_source never
check_freshness >"$T/chk" 2>&1; rc=$?
grep -q "\[OK\].*'fresh'.*reached the mount" "$T/chk" \
  || fail "check did not report the fresh source OK: $(cat "$T/chk")"
grep -q "\[WARN\].*'heal'.*STALE and was restarted" "$T/chk" \
  || fail "check did not report the healed source: $(cat "$T/chk")"
grep -q "\[FAULT\].*'stale'.*does NOT see changes" "$T/chk" \
  || fail "check did not FAULT the stale source: $(cat "$T/chk")"
grep -q "charon-mount@stale.service" "$T/chk" \
  || fail "the stale FAULT does not name the restart command"
grep -q "\[WARN\].*'gone'.*not tested" "$T/chk" \
  || fail "check did not report the untestable source: $(cat "$T/chk")"
grep -q "\[WARN\].*'never'.*never been tested" "$T/chk" \
  || fail "check did not report the never-tested source: $(cat "$T/chk")"
[ "$rc" != 0 ] || fail "check_freshness returned 0 with a stale source"

# ----------------------------------------------------------------- part 7 ----
# THE AUDIT HEALS ONLY UNDER THE SYNC LOCK. A heal restarts the mount, and a
# pass running at that moment would see its source vanish. With the lock held
# elsewhere it must measure and report, and restart nothing.
_mountc locked 1h; _source locked
: > "$T/restarts"
mkdir -p "$LOCKDIR"
( exec 9>"$LOCKFILE"; flock 9; : > "$T/held"
  while [ ! -e "$T/release" ]; do sleep 0.1; done ) &
_holder=$!
_w=0; until [ -e "$T/held" ]; do sleep 0.1; _w=$((_w + 1))
  [ "$_w" -lt 50 ] || fail "could not hold the lock"; done
audit_freshness locked >"$T/o7" 2>&1
# Wait for the HOLDER only: a bare `wait` would also wait on every rclone
# mount this shell started, which never exit, and hung this file on its first
# run.
: > "$T/release"; wait "$_holder"
[ -s "$T/restarts" ] && fail "the audit restarted a mount while a pass held
  the sync lock: $(cat "$T/restarts")" || :
[ "$(_rec locked RESULT)" = stale ] \
  || fail "under a held lock the stale result was not still recorded
  (record: $(_rec locked RESULT)): $(cat "$T/o7")"
# ...and with the lock free, it heals.
audit_freshness locked >"$T/o8" 2>&1
grep -qx 'charon-mount@locked.service' "$T/restarts" \
  || fail "with the lock free the audit did not heal: $(cat "$T/o8")"
[ "$(_rec locked RESULT)" = healed ] || fail "the audit's heal was not
  recorded: $(_rec locked RESULT)"

# THE AUDIT'S VERDICT counts a STALE mount as a finding and an UNTESTABLE one
# as not: the audit exits non-zero when it finds something wrong with what it
# audits, and "could not test" is not that (audit.t pins the other half).
_mountc stale2 1h; _source stale2
: > "$T/refuse-restart"
do_audit stale2 >"$T/o9" 2>&1; rc=$?
rm -f "$T/refuse-restart"
[ "$rc" != 0 ] || fail "the audit exited 0 over a mount it found stale"
do_audit gone >"$T/o10" 2>&1; rc=$?
[ "$rc" = 0 ] || fail "the audit failed over a mount it could not test (rc
  $rc), which is not a finding: $(cat "$T/o10")"

# ----------------------------------------------------------------- part 8 ----
# THE FILE IS NEVER CONTENT: every sync ignores it and the seed never copies
# it down, through the one shared fact rather than three literals.
never_content_excludes | grep -qxF "$FRESH_GLOB" \
  || fail "the seed does not exclude the freshness file"
grep -q '^ignore = Name @FRESH_GLOB@$' "$HERE/libexec/charon-sync" \
  || fail "the profile template does not ignore the freshness file"

pass "fresh, stale, healed, refused, untestable told apart; heal under lock"
