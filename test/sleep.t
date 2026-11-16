#!/bin/sh
# sleep.t - a suspend must never find unison waiting on the FUSE mount.
#
# THE INCIDENT, measured on dragonfly 2026-11-16. A lid closed three seconds
# into a pass and the box never slept: unison sat in an uninterruptible FUSE
# lookup, NetworkManager had taken the network, systemd froze rclone, and the
# kernel reported "1 tasks refusing to freeze ... task:unison" four attempts
# running. charon already held a sleep inhibitor, and it did nothing, because
# it was a BLOCK lock and logind ignores those for a lid close.
#
# So this pins, in order of how much each would cost if it regressed:
#
#   1. a pass running when logind announces a sleep is ENDED, under a DELAY
#      lock, children first, within the grace, leaving no unison behind;
#   2. that pass is INTERRUPTED, not failed: nothing recorded, nothing settled
#      (settling deletes resume temps), nothing flagged, exit 75. That includes
#      the incident's own shape, a pass that came back at exit 1 with 62
#      unreadable paths after a suspend that never happened;
#   3. a pass is not STARTED while a suspend is pending;
#   4. the watcher costs a healthy pass nothing: no end latency, statuses
#      preserved, and a supervisor that is itself ended takes unison with it.
#
# Real `timeout` and real `sleep` throughout, never stubs, because the claim
# is about a real process tree: timeout's CHILD is the thing that must die.
. "$(dirname "$0")/harness_lib"
harness_init sleep

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_TRAITS_DIR=$T/st
export CHARON_STATE=$T/state
export UNISON_DIR=$T/uni
export CHARON_SUSPEND_STATS=$T/stats
export CHARON_SLEEP_POLL=0.2
export CHARON_SLEEP_GRACE=1
CFG=$T/cfg
mkdir -p "$CFG/profiles.d" "$CFG/sources.d" "$T/st" "$T/uni" "$T/.cache" \
         "$T/bin" "$T/state" "$T/stats"

cat > "$T/st/s" <<'EOF'
PROBED=2026-01-01T00:00:00+00:00
WRITABLE=yes
CASE=sensitive
TIMES=settable
PERMS=none
LINKS=no
FSTYPE=ext4
EOF
cat > "$CFG/sources.d/s.conf" <<EOF
PROVIDER=none
MOUNT=$T/src
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=s:D\n' > "$CFG/profiles.d/docs.conf"
mkdir -p "$T/src/D" "$T/cache/D"
printf 'keep\n' > "$T/src/D/keep.txt"
printf 'keep\n' > "$T/cache/D/keep.txt"

# busctl: answers PreparingForSleep from a file, so a test can make logind
# "announce" a suspend at the exact moment it wants.
cat > "$T/bin/busctl" <<EOF
#!/bin/sh
case "\$*" in *PreparingForSleep*) ;; *) exit 1 ;; esac
if [ -e "$T/sleeping" ]; then echo 'b true'; else echo 'b false'; fi
EOF
chmod +x "$T/bin/busctl"
PATH="$T/bin:$PATH"; export PATH

CHARON_LIB_ONLY=1 . "$HERE/libexec/charon-sync"

_now() { date +%s; }
# A process carrying a UNIQUE duration, so "is it still running" has one
# answer and cannot be confused with any other sleep on the box.
#
# MATCHED ON THE EXACT ARGV, never `pgrep -f "sleep N"`: that pattern also
# matches any process whose command line merely CONTAINS the string, a shell
# running a script with it in an argument included, which reads a harness as a
# surviving unison (the process-table self-match the shared notes warn about,
# hit here while debugging this very file). A real survivor is a process whose
# whole argv is `sleep N`.
_pids() { pgrep -x sleep 2>/dev/null | while read -r _p; do
  [ "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" = "sleep $1 " ] \
    && echo "$_p"; done; }
_alive() { [ -n "$(_pids "$1")" ]; }
_reap() { for _p in $(_pids "$1"); do kill -KILL "$_p" 2>/dev/null; done; }

# ----------------------------------------------------------------- part 1 ----
# sleep_pending, level-triggered off logind's property.
rm -f "$T/sleeping"
sleep_pending && fail "sleep_pending said yes with PreparingForSleep false"
: > "$T/sleeping"
sleep_pending || fail "sleep_pending said no with PreparingForSleep true"
rm -f "$T/sleeping"
# A bus that cannot answer is "not that I can tell", never "yes": refusing
# every pass on a box whose bus is broken would stop the sync for a reason
# that has nothing to do with it.
printf '#!/bin/sh\nexit 1\n' > "$T/bin.busfail"; chmod +x "$T/bin.busfail"
( mkdir -p "$T/busfail"; cp "$T/bin.busfail" "$T/busfail/busctl"
  PATH="$T/busfail:$PATH"; : > "$T/sleeping"
  sleep_pending && exit 1; exit 0 ) \
  || fail "a FAILING busctl was read as a suspend in progress"
rm -f "$T/sleeping"

# ----------------------------------------------------------------- part 2 ----
# suspend_attempts: the counter that catches a suspend the watcher missed.
printf '2\n' > "$T/stats/success"; printf '4\n' > "$T/stats/fail"
[ "$(suspend_attempts)" = 6 ] \
  || fail "suspend_attempts read [$(suspend_attempts)], wanted 6 (2+4); a
  FAILED attempt is the one that matters, dragonfly never slept at all"
printf 'garbage\n' > "$T/stats/fail"
[ -z "$(suspend_attempts)" ] \
  || fail "suspend_attempts invented a number from garbage"
# AND IT MUST NOT ABORT ITS CALLER. dash treats garbage in $(( )) as a FATAL
# "Illegal number" and ends the whole shell, so without the guard a direct call
# would kill charon-sync mid-pass. Inside $( ) only the subshell dies and the
# empty answer above looks fine, which is why that assertion alone let the
# guard be deleted unnoticed. Asked DIRECTLY here, with stderr watched.
( suspend_attempts >/dev/null; echo survived ) >"$T/sa.out" 2>"$T/sa.err"
grep -qx survived "$T/sa.out" \
  || fail "suspend_attempts ABORTED its caller on garbage: $(cat "$T/sa.err")"
[ -s "$T/sa.err" ] && fail "suspend_attempts wrote to stderr on garbage:
  $(cat "$T/sa.err")" || :
rm -f "$T/stats/fail"
[ -z "$(suspend_attempts)" ] \
  || fail "suspend_attempts answered with a counter missing"
printf '4\n' > "$T/stats/fail"

# ----------------------------------------------------------------- part 3 ----
# supervise_sleep with NO suspend: invisible. Status preserved, no marker.
for rc in 0 1 2 3; do
  rm -f "$T/mark"
  supervise_sleep "$T/mark" "" sh -c "exit $rc"; got=$?
  [ "$got" = "$rc" ] || fail "supervise_sleep turned exit $rc into $got"
  [ -e "$T/mark" ] && fail "supervise_sleep wrote the marker with no suspend"
done

# NO END LATENCY, through run_teed, which is how every pass runs. The watcher
# is killed when the command ends, but a `sleep` it had started would hold the
# output pipe for up to one interval and tee would wait for it. Measured with
# a deliberately long poll so a leak is unmistakable.
_t0=$(_now)
CHARON_SLEEP_POLL=3 run_teed "$T/cap" supervise_sleep "" "" sh -c 'exit 2'
got=$?; _el=$(( $(_now) - _t0 ))
[ "$got" = 2 ] || fail "run_teed + supervise_sleep turned exit 2 into $got"
[ "$_el" -lt 2 ] \
  || fail "a 0s command took ${_el}s through run_teed: the watcher's sleep is
  holding the output pipe open, so every pass ends one poll interval late"

# pids_alive: a ZOMBIE IS NOT ALIVE. It has exited and only awaits reaping,
# and `kill -0` would call it alive, so the supervisor would hold the lock for
# its whole wait over a process that is already gone. A parent that execs
# into something that never reaps keeps a zombie around deterministically.
sh -c 'sleep 0.1 & exec sleep 40.6' &
_zp=$!
sleep 0.5
_z=$(pgrep -P "$_zp" 2>/dev/null)
case $(ps -o stat= -p "$_z" 2>/dev/null) in
  Z*) : ;; *) fail "the zombie fixture did not produce a zombie" ;;
esac
kill -0 "$_z" 2>/dev/null || fail "kill -0 no longer sees a zombie, so this
  case proves nothing"
pids_alive "$_z" && fail "pids_alive called a ZOMBIE alive"
pids_alive "$_zp" || fail "pids_alive called a running process dead"
kill -KILL "$_zp" 2>/dev/null; wait "$_zp" 2>/dev/null

# ----------------------------------------------------------------- part 4 ----
# A SUSPEND MID-RUN ENDS THE COMMAND, through a real `timeout`, whose CHILD is
# the process that has to die. Two children: one that honours TERM, and one
# that IGNORES it, which stands in for a unison whose TERM stays pending.
_midrun() {   # <unique-secs> <child-script>
  rm -f "$T/mark" "$T/sleeping"
  ( sleep 0.6; : > "$T/sleeping" ) &
  _t0=$(_now)
  supervise_sleep "$T/mark" "" timeout 60 sh -c "$2"; _mr=$?
  _el=$(( $(_now) - _t0 ))
  rm -f "$T/sleeping"
  if _alive "$1"; then _reap "$1"
    fail "the child survived the intervention (sleep $1 still running)"; fi
  [ -e "$T/mark" ] || fail "the watcher ended the command but left no marker,
  so the caller would record it as a FAILURE"
  [ "$_mr" != 0 ] || fail "an ended command reported success"
  # Under 0.6 (flip) + poll + grace + slack. Far under the child's own 40s.
  [ "$_el" -lt 6 ] || fail "ending the command took ${_el}s"
}
_midrun 40.1 'exec sleep 40.1'
_midrun 40.2 "trap '' TERM; exec sleep 40.2"

# AND IT REPORTS THE COMMAND'S STATUS, NOT ITS OWN. A trapped signal ends the
# supervisor's `wait` early with 128+n while the command is still tearing down;
# returning that would report a status nothing produced, before the command has
# actually gone. A command that takes a moment over its TERM and then exits 7
# tells the two apart: 7 is the command's answer, 143 is the interrupted wait.
rm -f "$T/sup.rc"
( supervise_sleep "" "" sh -c "trap 'sleep 0.5; exit 7' TERM
    while :; do sleep 0.1; done"; echo $? > "$T/sup.rc" ) &
_sup=$!
sleep 0.5
kill -TERM "$_sup"
wait "$_sup" 2>/dev/null
[ "$(cat "$T/sup.rc" 2>/dev/null)" = 7 ] \
  || fail "a supervisor ended by TERM returned [$(cat "$T/sup.rc" \
  2>/dev/null)], not its command's 7: it stopped waiting before the command
  had finished"

# A SUPERVISOR THAT IS ITSELF ENDED TAKES THE COMMAND WITH IT. Otherwise a
# stopped unit, or a Ctrl-C on an interactive pass, leaves unison running on
# the mount with nothing watching it.
rm -f "$T/sleeping"
( supervise_sleep "" "" timeout 60 sh -c 'exec sleep 40.3' ) &
_sup=$!
sleep 0.5
kill -TERM "$_sup"
wait "$_sup" 2>/dev/null
sleep 0.5
if _alive 40.3; then _reap 40.3
  fail "TERM to the supervisor left its command running"; fi

# ----------------------------------------------------------------- part 5 ----
# run_unison_guarded takes a DELAY lock and runs the pass under the watcher.
# A BLOCK lock is the regression: logind ignores it for a lid close, which is
# how the incident happened with an inhibitor already held.
cat > "$T/bin/systemd-inhibit" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/inhibit.log"
for a in "\$@"; do case "\$a" in --*) shift ;; *) break ;; esac; done
exec "\$@"
EOF
chmod +x "$T/bin/systemd-inhibit"
printf '#!/bin/sh\nexec sleep 40.4\n' > "$T/bin/unison"
chmod +x "$T/bin/unison"
: > "$T/inhibit.log"; rm -f "$T/mark" "$T/sleeping"
( sleep 0.6; : > "$T/sleeping" ) &
_t0=$(_now)
run_unison_guarded charon-docs "" "$T/mark" >/dev/null 2>&1
_el=$(( $(_now) - _t0 )); rm -f "$T/sleeping"
if _alive 40.4; then _reap 40.4
  fail "unison survived a suspend announced under the inhibitor"; fi
[ "$_el" -lt 6 ] || fail "run_unison_guarded took ${_el}s to end on a suspend"
[ -e "$T/mark" ] || fail "run_unison_guarded left no marker on a suspend"
grep -q -- '--mode=delay' "$T/inhibit.log" \
  || fail "the pass did not take a DELAY lock: $(cat "$T/inhibit.log")"
grep -q -- '--mode=block' "$T/inhibit.log" \
  && fail "a BLOCK lock was taken; logind ignores those for a lid close" || :
grep -q '__supervise' "$T/inhibit.log" \
  || fail "the lock does not wrap the supervisor, so it is not released the
  moment unison is gone: $(cat "$T/inhibit.log")"

# ----------------------------------------------------------------- part 6 ----
# pass_interrupted, each signal on its own.
rm -f "$T/mark"
[ -z "$(pass_interrupted docs 0 6 "$T/mark")" ] \
  || fail "a pass that SUCCEEDED was called interrupted"
: > "$T/mark"
[ -z "$(pass_interrupted docs 0 6 "$T/mark")" ] \
  || fail "a successful pass was called interrupted because of a marker"
pass_interrupted docs 2 6 "$T/mark" | grep -q 'charon ended the pass' \
  || fail "the watcher's marker did not make a failed pass interrupted"
rm -f "$T/mark"
printf '5\n' > "$T/stats/fail"
pass_interrupted docs 1 6 "" | grep -q 'attempted to suspend' \
  || fail "a moved suspend counter did not make a failed pass interrupted"
printf '4\n' > "$T/stats/fail"
[ -z "$(pass_interrupted docs 1 6 "")" ] \
  || fail "a failure with no suspend and a healthy source was called
  interrupted: $(pass_interrupted docs 1 6 "")"
# An UNKNOWN counter on either side is not evidence of a suspend.
[ -z "$(pass_interrupted docs 1 "" "")" ] \
  || fail "an unreadable starting counter was read as a suspend"
( source_health() { return 2; }
  pass_interrupted docs 1 6 "" | grep -q 'stopped answering' ) \
  || fail "a source gone offline did not make a failed pass interrupted"

# ----------------------------------------------------------------- part 7 ----
# END TO END, through the real command, the incident's own shapes.
for s in systemctl systemd-run mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/flags" > "$T/bin/notifier"
chmod +x "$T/bin/notifier"
# unison: what it does is chosen per case. `ioerr` is dragonfly's output after
# the thaw, unreadable paths in the scan-error column at exit 1, and it can
# bump the suspend counter first, which is the attempt the box made meanwhile.
cat > "$T/bin/unison" <<EOF
#!/bin/sh
: > "$T/unison.started"
case \$(cat "$T/unison.mode") in
  hang) exec sleep 40.5 ;;
  ioerr|ioerr-suspended)
    [ "\$(cat "$T/unison.mode")" = ioerr-suspended ] \\
      && printf '5\n' > "$T/stats/fail"
    printf '         error            Finance/Taxes/one.pdf  \n'
    printf 'Error in querying file information:\n'
    printf '         error            Games/Farkle scorecard.xlsx  \n'
    exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin/unison"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    CHARON_STATE=$T/state UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg \
    CHARON_NOTIFY=$T/bin/notifier sh "$HERE/bin/charon" "$@"
}
_c allow-push docs >/dev/null 2>&1 || fail "could not authorise the fixture"

# A RECORD AND A RESUME TEMP that must both survive an interrupted pass. The
# temp belongs to a path the interrupted list does not mention, which is
# exactly what SETTLING reads as "this path is fine now", and settling deletes
# the temp. That would be the interrupted pass destroying a resume point.
_seed_state() {
  mkdir -p "$T/state/failed"
  printf 'LAST=1\nRC=2\nFAILED=2 1 big video.mkv\n' \
    > "$T/state/failed/docs"
  cp "$T/state/failed/docs" "$T/record.before"
  printf 'partial' > "$T/cache/D/.unison.big video.mkv.c0ffee.unison.tmp"
  : > "$T/flags"; rm -f "$T/unison.started" "$T/sleeping"
  printf '4\n' > "$T/stats/fail"
}
_untouched() {   # <case>
  cmp -s "$T/state/failed/docs" "$T/record.before" \
    || fail "$1: the interrupted pass rewrote the failure record:
  $(cat "$T/state/failed/docs")"
  [ -e "$T/cache/D/.unison.big video.mkv.c0ffee.unison.tmp" ] \
    || fail "$1: the interrupted pass SETTLED from its cut-short list and
  deleted a resume temp"
  [ -s "$T/flags" ] && fail "$1: an interrupted pass raised a notify flag:
  $(cat "$T/flags")" || :
}

# E0: THE WATCHER MUST NOT HOLD THE SYNC LOCK. Every profile shares one flock
# on fd 9 and children inherit it, so a watcher `sleep` left over from one pass
# kept the lock for up to a poll interval, and a second pass started in that
# window SKIPPED. Two passes back to back, with a long poll so the window is
# wide enough to land in every time.
echo ok > "$T/unison.mode"
_c sync docs >/dev/null 2>&1 || fail "E0: the first of two passes failed"
CHARON_SLEEP_POLL=3 _c sync docs >/dev/null 2>&1
CHARON_SLEEP_POLL=3 _c sync docs >"$T/e0.out" 2>&1; rc=$?
[ "$rc" = 0 ] || fail "E0: a pass started straight after another exited $rc;
  something from the first still holds the sync lock: $(cat "$T/e0.out")"

# E1, THE CONTROL: the same unreadable paths with NO suspend are a real fault.
# Without this the cases below could pass because nothing records at all.
_seed_state; echo ioerr > "$T/unison.mode"
_c sync docs >"$T/e1.out" 2>&1; rc=$?
[ "$rc" != 75 ] && [ "$rc" != 0 ] \
  || fail "E1 control: a genuine failure exited $rc"
grep -q 'Farkle scorecard.xlsx' "$T/state/failed/docs" \
  || fail "E1 control: a genuine failure recorded nothing, so the cases below
  prove nothing: $(cat "$T/e1.out")"
[ -s "$T/flags" ] || fail "E1 control: a genuine failure raised no flag"

# E2: the incident's own shape. The box attempted a suspend during the pass
# and unison came back at exit 1 listing unreadable paths. Nothing is wrong
# with those paths.
_seed_state; echo ioerr-suspended > "$T/unison.mode"
_c sync docs >"$T/e2.out" 2>&1; rc=$?
[ "$rc" = 75 ] || fail "E2: a pass the box tried to suspend through exited
  $rc, not 75: $(cat "$T/e2.out")"
_untouched E2
grep -q 'INTERRUPTED, not failed' "$T/e2.out" \
  || fail "E2: the interrupted pass did not say so: $(cat "$T/e2.out")"

# E3: logind announces a suspend while unison is mid-pass.
_seed_state; echo hang > "$T/unison.mode"
( while [ ! -e "$T/unison.started" ]; do sleep 0.1; done
  sleep 0.3; : > "$T/sleeping" ) &
_t0=$(_now)
_c sync docs >"$T/e3.out" 2>&1; rc=$?
_el=$(( $(_now) - _t0 )); rm -f "$T/sleeping"
if _alive 40.5; then _reap 40.5
  fail "E3: unison survived a suspend announced mid-pass"; fi
[ "$rc" = 75 ] || fail "E3: a pass ended for a suspend exited $rc, not 75:
  $(cat "$T/e3.out")"
[ "$_el" -lt 10 ] || fail "E3: ending the pass took ${_el}s"
_untouched E3
grep -q 'a suspend is starting' "$T/e3.out" \
  || fail "E3: charon ended the pass without saying why"

# E4: a suspend already pending: the pass never touches the mount.
_seed_state; echo hang > "$T/unison.mode"; : > "$T/sleeping"
_c sync docs >"$T/e4.out" 2>&1; rc=$?
rm -f "$T/sleeping"
[ "$rc" = 75 ] || fail "E4: a pass with a suspend pending exited $rc"
[ -e "$T/unison.started" ] && fail "E4: unison STARTED while a suspend was
  pending" || :
_untouched E4

pass "a suspend ends the pass under a delay lock; interrupted is not failed"
