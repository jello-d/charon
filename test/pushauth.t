#!/bin/sh
# pushauth.t - a node must EARN the right to write the remote.
#
# THE HAZARD, measured 2026-10-05 before any of this existed. Put a stale cache
# beside a current remote with NO unison archive, and unison treats every
# local-only file as NEW and pushes it: a file the fleet DELETED months ago
# returns to the remote, at rc=0, with no warning. 500 of them is still rc=0,
# because `confirmbigdel` guards mass DELETION and this is mass ADDITION. That
# is the provisioning case, and with three nodes on one remote it is the
# realistic one.
#
# The conflict half was already handled (the stale version loses to
# `prefer = mount` and is twinned LOCALLY). RESURRECTION is the half nobody
# covered, and it is the worse one precisely because it reports success.
#
# The fix is safe-BY-CONSTRUCTION rather than a gate: until a profile is
# authorised, unison runs with -nocreation and -noupdate on the MOUNT root, so
# the remote cannot gain or lose anything while the cache still fills from it.
. "$(dirname "$0")/harness_lib"
harness_init pushauth

export HOME=$T
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/st" \
         "$T/mnt/D" "$T/cache/D"
for s in systemd-run mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
# systemctl must ANSWER, not exit 0 printing nothing. A silent stub leaves check
# reporting DRIFT for reasons unrelated to this test, and since DRIFT BEATS
# FAULT that would make the "pull-only does not change the verdict" assertion
# below unable to tell its own failure from the baseline's. That is exactly how
# the BYO-only defect hid inside provider.t.
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
SD=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
W=$SD/default.target.wants
mkdir -p "$W"
rc=0
a=
for x in "$@"; do
  case "$x" in
    --user|--now|--no-legend|-q|--quiet|--all) ;;
    *) a="$a $x" ;;
  esac
done
# shellcheck disable=SC2086
set -- $a
case "${1:-}" in
  enable)  shift
           for u in "$@"; do
             case "$u" in
               *@*.service) t=$SD/${u%%@*}@.service ;;
               *)           t=$SD/$u ;;
             esac
             ln -sfn "$t" "$W/$u"
           done ;;
  disable) shift; for u in "$@"; do rm -f "$W/$u"; done ;;
  is-enabled|is-active) [ -L "$W/$2" ] || rc=1 ;;
  list-unit-files)
    for f in "$SD"/*.service "$SD"/*.timer; do
      [ -e "$f" ] && printf '%s enabled\n' "${f##*/}"
    done 2>/dev/null ;;
  show)
    for x in "$@"; do
      case "$x" in
        Result)          echo success ;;
        ExecMainStatus)  echo 0 ;;
        ExecMainStartTimestamp|LastTriggerUSec)
                         echo "Sun 2026-10-05 00:00:00 EDT" ;;
      esac
    done ;;
esac
exit $rc
STUB
chmod +x "$T/bin/systemctl"
cat > "$CFG/sources.d/s.conf" <<EOF
PROVIDER=none
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=s:D\n' > "$CFG/profiles.d/docs.conf"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    CHARON_STATE=$T/st UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg \
    sh "$HERE/bin/charon" "$@"
}
_stale() {   # a fresh node whose cache is a stale restore
  rm -rf "$T/mnt" "$T/cache" "$T/uni" "$T/st"
  mkdir -p "$T/mnt/D" "$T/cache/D" "$T/st"
  echo current > "$T/mnt/D/kept.txt"
  echo filler  > "$T/mnt/D/other.txt"
  echo stale   > "$T/cache/D/kept.txt"
  echo zombie  > "$T/cache/D/resurrected.txt"
}

#### THE HAZARD ITSELF: a stale cache must not reach the remote ####
_stale
_c install >/dev/null 2>&1 || fail "install failed on a stale-cache node"
[ -f "$T/st/push-ok/docs" ] \
  && fail "install AUTHORISED a node with a non-empty cache and no archives;
    that is exactly the state charon cannot vouch for"
out=$(_c sync docs 2>&1); rc=$?
[ "$rc" = 0 ] || fail "a pull-only pass exited $rc; refusing to push is the
  guard working, not a failure ($out)"
[ -e "$T/mnt/D/resurrected.txt" ] \
  && fail "A FILE THE FLEET DELETED WAS PUSHED BACK TO THE REMOTE. This is the
    whole hazard: unison with no archive treats local-only files as new."
# ...while the legitimate direction still flows
grep -q current "$T/cache/D/kept.txt" \
  || fail "the remote's version did not reach the cache; pull-only must still
    pull, or a new node could never populate"
[ -f "$T/cache/D/other.txt" ] \
  || fail "a remote-only file was not pulled down on a pull-only pass"
# the local copy is kept, not destroyed: it is the only copy of whatever that
# cache held, and a human has to be able to look at it
[ -f "$T/cache/D/resurrected.txt" ] \
  || fail "the unpushed local file was DELETED; pull-only must refuse to push,
    not discard"
# and it must SAY SO, at a level charon-sync actually prints (LOG_LEVEL=2).
# ANCHORED ON THE ANNOUNCEMENT, not on the word: the completion note a few lines
# later also says "pull-only", so a bare grep for the word passed with the
# announcement demoted to log_trace and therefore invisible. Found by mutation.
printf '%s\n' "$out" | grep -q "profile 'docs' is PULL-ONLY" \
  || fail "the pass refused to push and did not ANNOUNCE it. A guard that is
    silent is indistinguishable from a broken sync ($out)"
printf '%s\n' "$out" | grep -q '\[WARN \]' \
  || fail "the announcement was not at WARN; charon-sync pins LOG_LEVEL=2, so
    anything lower is discarded and the guard becomes silent in production"

#### REPEATED PASSES KEEP REFUSING: the state is not a one-shot ####
for _i in 1 2; do
  _c sync docs >/dev/null 2>&1 || fail "pull-only pass $_i exited non-zero"
  [ -e "$T/mnt/D/resurrected.txt" ] \
    && fail "the guard held once and then leaked on pass $_i" || :
done

#### A GENUINE FAILURE WHILE PULL-ONLY IS STILL A FAILURE ####
# The guard's own skips exit 1, and so does an unreadable directory, so rc alone
# cannot tell them apart. A blanket rc-1 forgiveness would therefore swallow a
# real scan failure for as long as the profile stayed unauthorised, which is
# until a human intervenes. They ARE separable by the output: a scan failure
# emits the `error` column row, the guard's skips emit `<=?=>` rows.
mkdir -p "$T/cache/D/unreadable"
echo x > "$T/cache/D/unreadable/f.txt"
chmod 000 "$T/cache/D/unreadable"
out=$(_c sync docs 2>&1); rc=$?
chmod 755 "$T/cache/D/unreadable"
[ "$rc" = 0 ] \
  && fail "a REAL scan failure exited 0 while the profile was pull-only. The
    guard forgives exit 1, and a genuine scan error is also exit 1, so
    forgiving by rc alone hides it until a human authorises the profile ($out)"
printf '%s\n' "$out" | grep -q 'unreadable' \
  || fail "the failure did not name the path, which is how it is told apart
    from the guard's own skipped items ($out)"
rm -rf "$T/cache/D/unreadable" "$T/st/failed"

# ...and a PROPAGATION failure in the pull direction, which is exit 2. Induced
# with an unwritable cache subtree: the scan succeeds, the copies into the cache
# do not, and unison names each path. A NEW remote file is needed, or by this
# point the cache is already in step and there is nothing to fail at copying.
echo pullme > "$T/mnt/D/needspull.txt"
chmod 555 "$T/cache/D"
out=$(_c sync docs 2>&1); rc=$?
chmod 755 "$T/cache/D"
[ "$rc" = 0 ] \
  && fail "a propagation failure (exit 2) was forgiven as the guard's own
    skipped items; only exit 1 can be ($out)"
rm -rf "$T/st/failed"


#### check REPORTS it, as a WARN and never as a verdict ####
# Only a human can clear this, so a drift or fault verdict would make an
# integrator schedule an apply that cannot help: the crumb/twin reasoning.
_c sync docs >/dev/null 2>&1 || fail "the pass did not recover after cleanup"
out=$(_c check 2>&1); rc=$?
printf '%s\n' "$out" | grep -qi "profile 'docs' is PULL-ONLY" \
  || fail "check did not report the profile as pull-only ($out)"
printf '%s\n' "$out" | grep -q '\[WARN\].*PULL-ONLY' \
  || fail "pull-only was not reported at WARN; a verdict would make an
    integrator loop on a state only a human can clear"
[ "$rc" = 0 ] \
  || fail "pull-only moved check's VERDICT to $rc. Nothing an apply does can
    authorise a push, so a non-zero verdict makes an integrator schedule a
    repair that cannot work, which is the futile-loop bug one domain over:
$(printf '%s\n' "$out" | grep -E '\[FAIL\]|\[FAULT\]')"

#### plan: shows what WOULD happen, and writes NOTHING ####
# FRESH FIXTURE. The failure inductions above left unison's archive knowing
# about the unpushed file, so the plan had nothing to say about it and the
# assertion below started failing for a reason that was about test ordering
# rather than about plan. Each section from here owns its own state.
_stale
_c install >/dev/null 2>&1 || fail "install failed"
_before=$(cd "$T" && find mnt cache -printf '%p %s\n' | sort | md5sum)
out=$(_c plan docs 2>&1); rc=$?
[ "$rc" = 0 ] || fail "plan exited $rc ($out)"
_after=$(cd "$T" && find mnt cache -printf '%p %s\n' | sort | md5sum)
[ "$_after" = "$_before" ] \
  || fail "plan MODIFIED a replica; it must be read-only on BOTH sides"
printf '%s\n' "$out" | grep -q 'resurrected.txt' \
  || fail "plan did not name the file a pass would push, which is the one thing
    a human needs from it. THE NO-ARCHIVE CASE IS THE ONE THAT MATTERS: a node
    with no archive is exactly the one held pull-only and told to look ($out)"
printf '%s\n' "$out" | grep -q 'PULL-ONLY' \
  || fail "plan did not say the profile is currently pull-only ($out)"
# PLAN MUST NOT CREATE THE ARCHIVES IT REPORTS ON. unison writes them on any
# run, and push_safe_to_authorise reads their presence as "this node is already
# syncing", so an archive left behind by plan would mean that merely LOOKING at
# the plan silently authorised the node. Same trap as `-showarchive`.
ls "$T/uni"/ar* >/dev/null 2>&1 \
  && fail "plan created unison archives in the real UNISON dir. Their presence
    is what push_safe_to_authorise reads as 'already syncing', so looking at the
    plan would authorise the node it was meant to hold back."
_c install >/dev/null 2>&1 || fail "install failed after plan"
[ -f "$T/st/push-ok/docs" ] \
  && fail "after plan, install authorised the node; plan left something behind
    that push_safe_to_authorise read as safe"
printf '%s\n' "$out" | grep -qi 'Failure reading from the standard input' \
  && fail "plan leaked the EOF artifact of a defeated batch prompt" || :
printf '%s\n' "$out" | grep -qi 'Press return to continue' \
  && fail "plan is waiting for a human; with no archive unison ends its warning
    with that prompt, eats the EOF and exits before reconciling ($out)" || :
printf '%s\n' "$out" | grep -q 'UNISONLOCALHOSTNAME' \
  && fail "plan printed the whole no-archive boilerplate; its first line carries
    the fact, the rest is advice about DHCP" || :

#### allow-push: an explicit, recorded decision ####
_c allow-push nosuch >/dev/null 2>&1 \
  && fail "allow-push accepted an unknown profile" || :
_c allow-push >/dev/null 2>&1 \
  && fail "allow-push with no argument was accepted" || :
_c allow-push docs >/dev/null 2>&1 || fail "allow-push docs failed"
[ -f "$T/st/push-ok/docs" ] || fail "allow-push left no record"
grep -q '^REASON=' "$T/st/push-ok/docs" \
  || fail "the authorisation records no REASON; a decision with no artifact
    explaining itself is one nobody can audit later"
_c sync docs >/dev/null 2>&1 || fail "an authorised pass failed"
[ -e "$T/mnt/D/resurrected.txt" ] \
  || fail "after allow-push the pass still refused to push; the authorisation
    did not take effect"
_c check 2>&1 | grep -qi 'PULL-ONLY' \
  && fail "check still calls an authorised profile pull-only" || :

#### -noupdate IS LOAD-BEARING, and only a CONFLICT=local profile shows it ####
# With the default CONFLICT=remote the prf carries `prefer = <mount>`, so the
# remote wins every conflict and a stale cache cannot overwrite it even with the
# guard off. That masked the second half of the guard completely: the test could
# not tell -nocreation alone from -nocreation plus -noupdate. CONFLICT=local
# inverts the preference, and then OVERWRITING is exactly what an unauthorised
# node would do to a file the remote already holds.
_stale
printf 'SOURCE=s:D\nCONFLICT=local\n' > "$CFG/profiles.d/docs.conf"
_c install >/dev/null 2>&1 || fail "install failed with CONFLICT=local"
_c sync docs >/dev/null 2>&1 || fail "pull-only pass failed with CONFLICT=local"
grep -q current "$T/mnt/D/kept.txt" \
  || fail "A STALE LOCAL COPY OVERWROTE CURRENT REMOTE CONTENT. CONFLICT=local
    makes the cache win conflicts, so -nocreation alone is not enough: the
    remote gains nothing new and loses its current content instead."
# ...and the preference really was in effect, or the assertion above would pass
# for an unrelated reason (the whole point of a CONFLICT=local fixture).
_c allow-push docs >/dev/null 2>&1 || fail "allow-push failed"
_c sync docs >/dev/null 2>&1 || :
grep -q stale "$T/mnt/D/kept.txt" \
  || fail "once authorised the cache did NOT win the conflict, so CONFLICT=local
    was never in effect and the assertion above proved nothing"
printf 'SOURCE=s:D\n' > "$CFG/profiles.d/docs.conf"

#### NO MIGRATION CLIFF: an existing node authorises itself ####
# Every box already running charon has archives, so this release must not put
# any of them into pull-only and stop their pushes.
_stale
mkdir -p "$T/uni"
: > "$T/uni/ar0000000000000000000000000000dead"   # as a syncing node would have
_c install >/dev/null 2>&1 || fail "install failed on an existing node"
[ -f "$T/st/push-ok/docs" ] \
  || fail "a node WITH unison archives was put into pull-only. Every existing
    box has archives, so this would have stopped the whole fleet pushing."
grep -q 'REASON=install' "$T/st/push-ok/docs" \
  || fail "the auto-authorisation did not record why it was safe"

#### AN EMPTY CACHE IS THE LEGITIMATE FIRST SEED, and must not be gated ####
rm -rf "$T/mnt" "$T/cache" "$T/uni" "$T/st"
mkdir -p "$T/mnt/D" "$T/cache/D" "$T/st"
echo current > "$T/mnt/D/kept.txt"
_c install >/dev/null 2>&1 || fail "install failed on a fresh empty-cache node"
[ -f "$T/st/push-ok/docs" ] \
  || fail "an EMPTY cache was gated. There is nothing local to resurrect, and
    gating it would make a genuinely new node need a human for no reason."

#### AN rc THE PARSER CANNOT ATTRIBUTE MUST STILL FAIL ####
# The sharp case, and the reason the forgiveness pins the code to EXACTLY 1.
# Exit 3 is 'fatal error or interrupted', which charon deliberately excludes
# from the recorded set (an interrupted pass prints a truncated list), so the
# no-attributable-path test is satisfied and cannot exclude it. Forgiving `rc >=
# 1` would therefore report a fatally broken pass as a successful pull-only one,
# for as long as the profile stayed unauthorised, which is until a human acts.
#
# Induced through the documented Tier 2 escape hatch, which is how a profile
# realistically acquires a bad preference. It has to exist BEFORE install: the
# `include` line is only rendered when the file is there, and hand-appending it
# to the live prf would be drift that check would rightly report.
_stale
mkdir -p "$T/uni"   # _stale removes it, so the write below would go nowhere
printf 'nosuchpreference = yes\n' > "$T/uni/charon-docs.prf.local"
_c install >/dev/null 2>&1 || :
[ -f "$T/st/push-ok/docs" ] \
  && fail "the fixture authorised itself, so the pass below would not be
    pull-only and the assertion would prove nothing"
out=$(_c sync docs 2>&1); rc=$?
rm -f "$T/uni/charon-docs.prf.local"
[ "$rc" = 0 ] \
  && fail "a FATAL unison error (exit 3) was reported as a successful pull-only
    pass ($out)"
printf '%s\n' "$out" | grep -q 'not a valid option' \
  || fail "the fixture did not actually induce a fatal unison error, so the
    assertion above passed for an unrelated reason ($out)"

pass "pull-only until authorised: no resurrection, no migration cliff"
