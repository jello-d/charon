#!/bin/sh
# fuse.t - REAL FUSE mounts: a stuck request, a dead mount, and the release.
#
# sleep.t proves the supervisor's logic with stubs; this proves the parts that
# only the KERNEL can answer, because the second lid test on dragonfly
# (2026-11-16) failed on exactly those: the watcher fired, killed unison, and
# unison stayed. Everything here was measured by hand first, then pinned:
#
#   1. a waiter whose request rclone has TAKEN survives SIGKILL in D state,
#      and aborting the connection frees it;
#   2. after the daemon dies the mount is a husk that `mountpoint -q` calls
#      mounted on one box and not on another, so charon must clear it itself;
#   3. no probe of a stuck mount may wait on it: a `stat` there is unkillable;
#   4. `charon source release` aborts only what charon owns, and only when a
#      request is actually waiting;
#   5. the supervisor holds on until the stuck unison is really gone.
#
# The stuck mount is rclone's http backend pointed at a local server that
# ACCEPTS and never answers, which is the incident's shape: a request handed
# to rclone, rclone waiting on a connection that will never speak.
#
# Mounts live under the harness's /tmp scratch dir, which the fusermount3
# AppArmor profile permits. Skipped, loudly, wherever FUSE cannot be used.
. "$(dirname "$0")/harness_lib"
harness_init fuse

for _need in rclone fusermount3 python3 pgrep; do
  command -v "$_need" >/dev/null 2>&1 || skip "$_need not available"
done
[ -w /dev/fuse ] || skip "/dev/fuse is not usable here"

# CLEANUP BEFORE THE HARNESS'S DELETE, AND IT REPLACES THAT TRAP. A live mount
# under $T would let `rm -rf` descend into it, and a stuck one would hang the
# delete. So: end the server (which unsticks rclone), end every rclone, detach
# every mount lazily, and only then remove $T, baked in as a literal.
#
# THE MOUNTS COME FROM THE KERNEL'S TABLE, never from a test on the path: the
# first version asked `[ -d "$m" ]`, which is false for a DEAD mount (ENOTCONN),
# so it skipped exactly the husks and left three mounts behind.
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
export CHARON_SLEEP_POLL=0.2
export CHARON_SLEEP_GRACE=1
mkdir -p "$T/cfg/sources.d" "$T/state" "$T/st" "$T/src" "$T/bin"
printf 'hello\n' > "$T/src/f"
: > "$T/pids"

# A server that accepts and never answers.
python3 -I - "$T/port" <<'PY' &
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(64)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
held = []
while True:
    c, _ = s.accept(); held.append(c)
PY
echo $! >> "$T/pids"
_w=0; until [ -s "$T/port" ]; do
  sleep 0.1; _w=$((_w + 1)); [ "$_w" -lt 50 ] || fail "no silent server"
done
cat > "$RCLONE_CONFIG" <<EOF
[stuck]
type = http
url = http://127.0.0.1:$(cat "$T/port")/

[loc]
type = alias
remote = $T/src
EOF

CHARON_LIB_ONLY=1 . "$HERE/libexec/charon-sync"

# systemctl: answers MainPID for a mount unit from a file, so `release` can be
# watched killing the right daemon. Nothing else is asked of it here.
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
for a in "\$@"; do u=\$a; done
case "\$*" in *MainPID*) cat "$T/mainpid.\$u" 2>/dev/null || echo 0 ;; esac
exit 0
EOF
cat > "$T/bin/busctl" <<EOF
#!/bin/sh
if [ -e "$T/sleeping" ]; then echo 'b true'; else echo 'b false'; fi
EOF
chmod +x "$T/bin/systemctl" "$T/bin/busctl"
PATH="$T/bin:$PATH"; export PATH

_mount() {   # <remote> <name> -> prints the rclone pid
  mkdir -p "$T/m-$2"
  rclone mount "$1:" "$T/m-$2" --dir-cache-time 1s \
    >"$T/rclone-$2.log" 2>&1 </dev/null &
  echo $! >> "$T/pids"
  _mp=$!
  _mw=0
  until [ -n "$(mount_device "$T/m-$2")" ]; do
    sleep 0.1; _mw=$((_mw + 1))
    [ "$_mw" -lt 100 ] || fail "mount $2 never came up: $(cat \
      "$T/rclone-$2.log")"
  done
  echo "$_mp"
}
# A WAITER: a process stuck on a request rclone has taken. Its argv is unique,
# so finding it never matches anything else on the box.
_waiter() {   # <name> -> prints the pid
  stat "$T/m-$1/waiter-$1" >/dev/null 2>&1 </dev/null &
  echo $! >> "$T/pids"
  echo $!
}
_state() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' '; }
_now() { date +%s; }

# ----------------------------------------------------------------- part 1 ----
# endpoint_state: four answers, and the one about a stuck mount must ARRIVE.
mkdir -p "$T/m-none"
[ "$(endpoint_state "$T/m-none")" = none ] \
  || fail "a plain directory did not read as none"
_mount loc live >/dev/null
[ "$(endpoint_state "$T/m-live")" = live ] \
  || fail "a healthy mount did not read as live"
_dp=$(_mount loc dead)
kill -KILL "$_dp"; sleep 0.5
[ "$(endpoint_state "$T/m-dead")" = dead ] \
  || fail "a mount whose daemon was killed did not read as dead"
_sp=$(_mount stuck stuck)
_wp=$(_waiter stuck); sleep 1
# THE PROPERTY IS THAT IT ANSWERS, not which word. rclone serves requests
# concurrently, so with one lookup stuck the daemon still answers a statfs and
# `live` is TRUE; this file first asserted `stuck` here and was wrong. What
# must never happen is the probe joining the waiter.
[ "$(cat "/sys/fs/fuse/connections/$(mount_device "$T/m-stuck" \
  | cut -d: -f2)/waiting")" -ge 1 ] \
  || fail "the waiter is not waiting on the stuck mount, so this tests nothing"
_t0=$(_now)
_es=$(endpoint_state "$T/m-stuck" 10)
_el=$(( $(_now) - _t0 ))
case $_es in live|stuck) : ;; *) fail "a stuck-request mount read as [$_es]" ;;
esac
[ "$_el" -lt 4 ] || fail "endpoint_state took ${_el}s on a mount with a stuck
  request: a probe that waits on the mount is the hang it exists to avoid"

# A WHOLLY WEDGED DAEMON reads `stuck`, and the probe still comes back. A
# SIGSTOPped rclone takes no requests at all, so a statfs waits for as long as
# it stays stopped; endpoint_state must abandon its probe, not join it.
_wedge=$(_mount loc wedged)
kill -STOP "$_wedge"
_t0=$(_now)
_es=$(endpoint_state "$T/m-wedged" 10)
_el=$(( $(_now) - _t0 ))
kill -CONT "$_wedge"
[ "$_es" = stuck ] || fail "a SIGSTOPped daemon read as [$_es], not stuck"
[ "$_el" -lt 4 ] || fail "endpoint_state took ${_el}s on a wedged daemon"

# mount_device on a path with a SPACE. The table escapes it as \040, and an
# `awk -v` comparison turns the escape back into a space and never matches.
printf '36 25 0:99 / /home/x/My\\040Drive rw - fuse.rclone x rw\n' \
  > "$T/mountinfo.fake"
[ "$(CHARON_MOUNTINFO=$T/mountinfo.fake mount_device '/home/x/My Drive')" \
  = 0:99 ] || fail "mount_device missed a mount point containing a space"

# ----------------------------------------------------------------- part 2 ----
# THE KERNEL FACT EVERYTHING ELSE RESTS ON, asserted rather than remembered: a
# waiter whose request rclone has taken survives SIGKILL. If a kernel ever
# changes this, the release stops being necessary, and this says so first.
kill -KILL "$_wp"; sleep 1
case $(_state "$_wp") in
  D*) : ;;
  *) fail "a waiter on a TAKEN request died of SIGKILL (state now
  '$(_state "$_wp")'); the kernel semantic this design rests on has changed" ;;
esac

# ----------------------------------------------------------------- part 3 ----
# release refuses what it must not touch, and frees what it must.
cat > "$T/cfg/sources.d/byo.conf" <<EOF
PROVIDER=none
MOUNT=$T/m-stuck
CACHE_ROOT=$T/cache-byo
EOF
cat > "$T/cfg/sources.d/s.conf" <<EOF
PROVIDER=rclone
REMOTE=stuck
MOUNT=$T/m-stuck
CACHE_ROOT=$T/cache-s
EOF
cat > "$T/cfg/sources.d/l.conf" <<EOF
PROVIDER=rclone
REMOTE=loc
MOUNT=$T/m-live
CACHE_ROOT=$T/cache-l
EOF
_src() { sh "$HERE/libexec/charon-source" "$@"; }
# Not charon's tree: refused, and the waiter is still waiting.
_src release byo >"$T/r.out" 2>&1 \
  && fail "release tore down a PROVIDER=none mount: $(cat "$T/r.out")"
case $(_state "$_wp") in D*) : ;; *) fail "release on a BYO source freed
  the waiter anyway, so it aborted a mount charon does not own" ;; esac
# Nothing waiting: refused, and the healthy mount stays healthy.
_src release l >"$T/r.out" 2>&1 \
  && fail "release aborted a mount with NO waiting request: $(cat "$T/r.out")"
[ "$(endpoint_state "$T/m-live")" = live ] \
  || fail "release on an idle mount broke it"
# THE ABORT ALONE, with no daemon to kill: the unit reports no MainPID (a mount
# brought up by hand, say). Killing the daemon would also free the waiter, as
# a dead daemon takes its connection with it, which is why a test that always
# supplies a MainPID could not tell whether the abort did anything at all;
# mutation testing showed exactly that. Here only the abort can do it.
_s3=$(_mount stuck stuck3)
_w3=$(_waiter stuck3); sleep 1
cat > "$T/cfg/sources.d/s3.conf" <<EOF
PROVIDER=rclone
REMOTE=stuck
MOUNT=$T/m-stuck3
CACHE_ROOT=$T/cache-s3
EOF
_src release s3 >"$T/r3.out" 2>&1 \
  || fail "release refused a stuck mount with no known daemon: $(cat \
  "$T/r3.out")"
sleep 1
[ -z "$(_state "$_w3")" ] || fail "the ABORT did not free the stuck waiter
  (state $(_state "$_w3")); with no daemon to kill, nothing else could"
grep -q 'no running daemon' "$T/r3.out" \
  || fail "release did not say the mount has no daemon to restart it"
case $(_state "$_s3") in ''|Z*) fail "with no MainPID, release killed a
  daemon anyway" ;; esac

# The real thing: the waiter goes, and the daemon is killed so its unit
# restarts it.
echo "$_sp" > "$T/mainpid.charon-mount@s.service"
_src release s >"$T/r.out" 2>&1 \
  || fail "release refused a stuck rclone mount: $(cat "$T/r.out")"
sleep 1
[ -z "$(_state "$_wp")" ] || fail "release did not free the stuck waiter (state
  $(_state "$_wp")): $(cat "$T/r.out")"
_ss=$(_state "$_sp")
case $_ss in ''|Z*) : ;; *) fail "release left the mount's daemon running
  (state $_ss), so its unit would never restart it" ;; esac

# ----------------------------------------------------------------- part 4 ----
# charon-mount up over a DEAD husk clears it and mounts; over a STUCK mount
# it refuses, promptly. Both used to be decided by `mountpoint -q`.
cat > "$T/cfg/sources.d/d.conf" <<EOF
PROVIDER=rclone
REMOTE=loc
MOUNT=$T/m-dead
CACHE_ROOT=$T/cache-d
EOF
CHARON_SOURCE=d sh "$HERE/libexec/charon-mount" run >"$T/up.out" 2>&1 &
echo $! >> "$T/pids"
_w=0
until [ "$(endpoint_state "$T/m-dead")" = live ]; do
  sleep 0.2; _w=$((_w + 1))
  [ "$_w" -lt 50 ] || fail "charon-mount up did not bring a mount back over
  a dead husk: $(cat "$T/up.out")"
done
[ "$(cat "$T/m-dead/f")" = hello ] || fail "the remount is not serving files"
_s2=$(_mount stuck stuck2)
_w2=$(_waiter stuck2); sleep 1
cat > "$T/cfg/sources.d/s2.conf" <<EOF
PROVIDER=rclone
REMOTE=stuck
MOUNT=$T/m-stuck2
CACHE_ROOT=$T/cache-s2
EOF
# DOWN over a dead husk detaches it. It used to ask `mountpoint -q`, which
# on this box calls a husk unmounted, so the husk survived every stop.
_hp=$(_mount loc husk)
kill -KILL "$_hp"; sleep 0.5
cat > "$T/cfg/sources.d/h.conf" <<EOF
PROVIDER=rclone
REMOTE=loc
MOUNT=$T/m-husk
CACHE_ROOT=$T/cache-h
EOF
CHARON_SOURCE=h sh "$HERE/libexec/charon-mount" stop >"$T/down.out" 2>&1
[ -z "$(mount_device "$T/m-husk")" ] || fail "charon-mount down left a dead
  mount in place: $(cat "$T/down.out")"

# Over a mount with a STUCK REQUEST: it must answer promptly and must not
# stack a second mount on the first, whichever way it reads the daemon.
_t0=$(_now)
CHARON_SOURCE=s2 timeout 20 sh "$HERE/libexec/charon-mount" run \
  >"$T/up2.out" 2>&1 </dev/null
_el=$(( $(_now) - _t0 ))
[ "$_el" -lt 10 ] || fail "charon-mount up took ${_el}s on a mount with a
  stuck request: $(cat "$T/up2.out")"
_n=$(awk -v m="$T/m-stuck2" '$5 == m' /proc/self/mountinfo | wc -l)
[ "$_n" = 1 ] || fail "charon-mount up left $_n mounts at one mountpoint"

# ----------------------------------------------------------------- part 5 ----
# THE SUPERVISOR, END TO END ON A REAL STUCK MOUNT, which is dragonfly's
# second lid test: a suspend starts, the watcher kills, the "unison" stays in
# D, the source is released, and the supervisor does not return (which is
# what lets the lock go) until that process is really gone.
echo "$_s2" > "$T/mainpid.charon-mount@s2.service"
kill -KILL "$_w2" 2>/dev/null
rm -f "$T/sleeping" "$T/mark"
( sleep 1.5; : > "$T/sleeping" ) &
_t0=$(_now)
supervise_sleep "$T/mark" s2 timeout 60 stat "$T/m-stuck2/unison-standin" \
  >"$T/sup.out" 2>&1
_el=$(( $(_now) - _t0 )); rm -f "$T/sleeping"
for _p in $(pgrep -x stat 2>/dev/null); do
  case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
    *"/m-stuck2/unison-standin"*)
      fail "the supervisor returned with the stuck process still alive
  (pid $_p, state $(_state "$_p")): that releases the lock too early.
  $(cat "$T/sup.out")" ;;
  esac
done
grep -q "Releasing source" "$T/sup.out" \
  || fail "the supervisor never escalated to a release: $(cat "$T/sup.out")"
[ "$_el" -lt 15 ] || fail "ending a stuck pass took ${_el}s"

# ----------------------------------------------------------------- part 6 ----
# WHEN NOTHING CAN BE RELEASED, HOLD THE LOCK FOR THE WAIT AND SAY SO. A
# bring-your-own source is refused by release (charon does not own it), so
# the only thing left is time: the daemon may still answer inside logind's
# window. The supervisor must keep waiting for the bounded period rather than
# returning at once, and must warn that this suspend may fail, rather than
# report a clean intervention it did not achieve.
_s4=$(_mount stuck stuck4)
cat > "$T/cfg/sources.d/byo4.conf" <<EOF
PROVIDER=none
MOUNT=$T/m-stuck4
CACHE_ROOT=$T/cache-byo4
EOF
rm -f "$T/sleeping" "$T/mark"
( sleep 1.5; : > "$T/sleeping" ) &
_t0=$(_now)
CHARON_SLEEP_RELEASE_WAIT=30 supervise_sleep "$T/mark" byo4 \
  timeout 60 stat "$T/m-stuck4/byo-standin" >"$T/sup4.out" 2>&1
_el=$(( $(_now) - _t0 )); rm -f "$T/sleeping"
grep -q 'STILL waiting on the mount' "$T/sup4.out" \
  || fail "with nothing it could release, the supervisor did not warn that
  the suspend may fail: $(cat "$T/sup4.out")"
[ "$_el" -ge 5 ] || fail "with nothing it could release, the supervisor gave
  up after ${_el}s instead of holding the lock for its 3s wait"
# Unstick the stand-in this case deliberately left behind.
printf '1\n' > "/sys/fs/fuse/connections/$(mount_device "$T/m-stuck4" \
  | cut -d: -f2)/abort" 2>/dev/null || :

pass "a taken request outlives SIGKILL; release frees it; dead mounts recover"
