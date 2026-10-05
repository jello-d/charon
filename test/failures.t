#!/bin/sh
# failures.t - learning WHICH paths a pass failed on, from unison's own output.
#
# THE GAP THIS CLOSES. charon reported unison's EXIT CODE and never read a word
# of its output, so a fault said "exit 2, go read the log". On 2026-09-24 that
# meant a human grepping the journal by hand for six paths unison had already
# printed plainly, on both boxes, every pass, for four hours. The information
# was always there; nothing collected it.
#
# Two things need holding down hard, because this is the first code here that
# depends on unison's OUTPUT rather than its exit status:
#
#   1. THE PARSE, against real unison output, including a path with spaces,
#      every name that has ever caused trouble in this project has had spaces.
#   2. THE TRUST GATE. A list is only complete if unison reached its own
#      verdict (exit 0/1/2). Exit 3 is "fatal error OR EXECUTION INTERRUPTED"
#      and charon's own `timeout` kill gives 124/137. A truncated list recorded
#      as fact is how the cleanup built on top of this could delete a temp that
#      a resume still needs, so the guard is asserted from both sides.
. "$(dirname "$0")/harness_lib"
harness_init failures

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_TRAITS_DIR=$T/st
export CHARON_STATE=$T/state
export UNISON_DIR=$T/uni
CFG=$T/cfg
mkdir -p "$CFG/profiles.d" "$CFG/sources.d" "$T/st" "$T/uni" "$T/.cache" \
         "$T/bin" "$T/state"

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

CHARON_LIB_ONLY=1 . "$HERE/libexec/charon-sync"
_self=$HERE/libexec/charon-sync

# ----------------------------------------------------------------- part 1 ----
# THE PARSE. The sample is unison's real wording, captured from unison 2.53.8
# under the exact flags charon uses (-batch -auto -ui text -silent).
# tabs-are-data: a byte-level unison transcript, reproduced exactly.
# THE TWO TAB-INDENTED LINES BELOW ARE DATA, NOT INDENTATION. unison really
# does indent those two paths with a literal tab, and this sample is a
# byte-level reproduction of its output, and retabbing them to spaces would
# falsify the very thing the parse is being tested against. The house rule is 2
# spaces and no tabs; a captured transcript is not source formatting.
cat > "$T/out" <<'EOF'
Warning: No archive files were found for these roots, whose canonical names are:
  /tmp/x/L
  /tmp/x/R
[BGN] Copying sub/decoy.png from /tmp/x/L to /tmp/x/R
[END] Copying sub/decoy.png
Failed [sub/Fenix Watchface - tuned.psp]: Error in copying locally:
  some indented continuation line that must NOT be read as a path
Failed [sub/second file.png]: Error in copying locally:
Failed [plain.txt]: Destination updated during synchronization
The file plain.txt has been created
Failed [sub/second file.png]: Error in copying locally:
EOF
# The [BGN]/[END] lines above are REAL unison output and are BRACKETED, which
# is what forces the parse to be anchored on "Failed [" rather than on "some
# text in brackets". Without them a parse loosened to any bracketed text passes
# this test unchanged, measured by mutation, and it did.
got=$(parse_unison_failures "$T/out")
want='plain.txt
sub/Fenix Watchface - tuned.psp
sub/second file.png'
[ "$got" = "$want" ] || fail "parse_unison_failures got:
$got
want:
$want"

# A path WITH SPACES survives, which is the whole reason the bracketed form is
# parseable at all.
printf '%s\n' "$got" | grep -qx 'sub/Fenix Watchface - tuned.psp' \
  || fail "a path containing spaces did not survive the parse"
# A path containing ']' survives, because the capture is greedy.
printf 'Failed [odd]name.txt]: Error\n' > "$T/out2"
[ "$(parse_unison_failures "$T/out2")" = 'odd]name.txt' ] \
  || fail "a path containing ']' was truncated by the parse"
# No input, no output, no error.
[ -z "$(parse_unison_failures "$T/nonexistent")" ] \
  || fail "parse_unison_failures invented output for a missing file"


# --- FORM 2: the SCAN failure row, exit 1 -------------------------------------
# Missing this was a LIVE blind spot: an exit-1 fault recorded no paths, so it
# reported nothing, built no streak and never unwedged. The row below is real
# unison output, byte for byte: nine spaces, "error", twelve spaces, the path,
# two trailing spaces. Captured 2026-09-26.
cat > "$T/scan" <<'EOF'
Contacting server...
Looking for changes
         error            unreadable.txt  
Error in digesting /tmp/x/L/unreadable.txt:
/tmp/x/L/unreadable.txt: Permission denied
         error            a long dir/deep/Fenix Watchface - tuned.psp  
         error            blocked dir  
EOF
got=$(parse_unison_failures "$T/scan")
want='a long dir/deep/Fenix Watchface - tuned.psp
blocked dir
unreadable.txt'
[ "$got" = "$want" ] || fail "the SCAN-failure wording was not parsed. got:
$got
want:
$want"

# THE ROW IS THE ONLY RELIABLE SOURCE, which is why it and not the companion
# line is parsed. Measured across four inductions: an unreadable FILE gives
# `Error in digesting <ABSOLUTE path>:`, an unreadable DIRECTORY gives `Error in
# scanning directory:` with NO PATH AT ALL, and a fifo or a socket gives no
# companion line whatsoever. Only the `error` row is always present, and only it
# is root-relative.
printf 'Error in scanning directory:\n' > "$T/nopath"
[ -z "$(parse_unison_failures "$T/nopath")" ] \
  || fail "a companion line with no path in it yielded a path anyway:
  $(parse_unison_failures "$T/nopath")"
printf 'Error in digesting /abs/olute/path.txt:\n' > "$T/abspath"
[ -z "$(parse_unison_failures "$T/abspath")" ] \
  || fail "an ABSOLUTE-path companion line was parsed as a relative path, which
  would send every crumb lookup to a directory that does not exist:
  $(parse_unison_failures "$T/abspath")"

# BOTH WORDINGS AT ONCE, merged and deduplicated. They are disjoint in practice
# (rc 2 emits only Failed[], rc 1 only the error row) but nothing should depend
# on that.
cat > "$T/both" <<'EOF'
Failed [propagated.psp]: Error in copying locally:
         error            scanned.txt  
Failed [shared name.txt]: Destination updated during synchronization
         error            shared name.txt  
EOF
[ "$(parse_unison_failures "$T/both")" = 'propagated.psp
scanned.txt
shared name.txt' ] \
  || fail "the two wordings did not merge and dedupe:
  $(parse_unison_failures "$T/both")"

# A NORMAL table row must NOT be read as a failure. These are what unison prints
# for ordinary items, and a pattern loose enough to eat them would report every
# synced file as failing.
# The last row is the one that makes the COLUMN anchor visible rather than just
# defensible: a file really named "error  report.txt" (a double space is a legal
# filename, and this Drive is full of odd names). Anchored on the status column,
# it is correctly ignored. Anchored on the WORD error anywhere in the line, it
# would yield a phantom path "report.txt" from a file that synced perfectly.
cat > "$T/normal" <<'EOF'
new file ---->            big.bin  
file     ---->            plain.txt  
         props            meta.txt  
<---- changed             other.txt  
         props            error  report.txt  
EOF
[ -z "$(parse_unison_failures "$T/normal")" ] \
  || fail "ordinary reconciliation rows were parsed as failures:
  $(parse_unison_failures "$T/normal")"

# ...and the SAME awkward name, when it really does fail, parses in full.
printf '         error            error  report.txt  \n' > "$T/awkward"
[ "$(parse_unison_failures "$T/awkward")" = 'error  report.txt' ] \
  || fail "a failing file whose own name starts with 'error  ' was mangled:
  [$(parse_unison_failures "$T/awkward")]"

# ----------------------------------------------------------------- part 2 ----
# THE TRUST GATE, asserted from both sides.
for rc in 0 1 2; do
  unison_rc_reported "$rc" \
    || fail "unison_rc_reported rejected $rc, which unison documents as a
    verdict it reached on its own (0 up to date, 1 skipped, 2 transfer failed)"
done
for rc in 3 124 125 137; do
  unison_rc_reported "$rc" \
    && fail "unison_rc_reported ACCEPTED $rc: 3 is 'fatal error or execution
    interrupted' and 124/137 are charon's own timeout kill, so the failure list
    is truncated and must never be recorded as fact"
done

# record_failures HONOURS the gate: an untrusted rc must leave the PREVIOUS
# record standing, not replace it with a partial one and not delete it.
record_failures docs 2 "$T/out"
_first=$(failed_paths docs)
[ -n "$_first" ] || fail "record_failures recorded nothing on a trusted rc 2"
printf 'Failed [only-one.txt]: Error\n' > "$T/truncated"
for rc in 3 124 137; do
  record_failures docs "$rc" "$T/truncated"
  [ "$(failed_paths docs)" = "$_first" ] \
    || fail "record_failures overwrote the record from an rc $rc run, whose
    list is incomplete by definition"
done

# A SUCCESSFUL run with no failures CLEARS the record, so its absence is the
# signal that the profile is clean.
: > "$T/clean"
record_failures docs 0 "$T/clean"
[ -z "$(failed_paths docs)" ] \
  || fail "a clean pass did not clear the failed-path record"
[ ! -f "$(failed_file docs)" ] \
  || fail "a clean pass left the record FILE behind; its absence is the signal"

# ...but a FAILING run that charon cannot ATTRIBUTE must NOT clear it. "I parsed
# no paths" is not "nothing is failing", and the difference is load-bearing:
# unison words a PROPAGATION failure as `Failed [path]:` and exits 2, while a
# SCAN or digest failure (an unreadable source file) is worded otherwise and
# exits 1. Measured 2026-09-26. Wiping the record on that would also wipe a
# streak that was about to unwedge a real fault.
record_failures docs 2 "$T/out"
_keep=$(failed_paths docs)
[ -n "$_keep" ] || fail "setup for the unattributable case recorded nothing"
for rc in 1 2; do
  _msg=$(record_failures docs "$rc" "$T/clean" 2>&1)
  [ "$(failed_paths docs)" = "$_keep" ] \
    || fail "an rc $rc pass that charon could not attribute to any path WIPED
    the record; it now holds: [$(failed_paths docs)]"
  case $_msg in
    *"could not attribute"*) : ;;
    *) fail "charon silently ignored an rc $rc failure it could not parse; a
       blind spot has to be LOUD: $_msg" ;;
  esac
done

# ----------------------------------------------------------------- part 3 ----
# EACH PATH'S HISTORY IS ITS OWN, and that is the fix for a real defect rather
# than a refinement. Keying first-seen and the streak on the whole SET meant
#
#     pass 1  {A, B}      pass 2  {A, B, C}      pass 3  {A, B}
#
# reset both every single time, so a fault whose set SHIFTS (one path
# intermittently succeeding, new files arriving in a broken folder) reported
# "first seen 0s ago" forever and could NEVER reach the unwedge threshold. The
# chronic case was both invisible and unfixable.
_rec() {   # <profile> <path> -> "<streak> <since>", or nothing
  failed_records "$1" | while IFS= read -r _r; do
    _k=${_r%% *}; _rest=${_r#* }; _s=${_rest%% *}; _p=${_rest#* }
    [ "$_p" = "$2" ] || continue
    printf '%s %s\n' "$_k" "$_s"
  done
}
_streak() { _rec "$1" "$2" | cut -d' ' -f1; }
_since()  { _rec "$1" "$2" | cut -d' ' -f2; }

rm -rf "$T/state/failed"
printf 'Failed [alpha.txt]: E\nFailed [beta.txt]: E\n' > "$T/ab"
record_failures docs 2 "$T/ab"
[ "$(_streak docs alpha.txt)" = 1 ] || fail "alpha's first sighting is not 1"
_a1=$(_since docs alpha.txt)
[ -n "$_a1" ] || fail "no first-seen recorded for alpha.txt"

# The SAME set again: both advance, both keep their first-seen.
#
# BACKDATED first, so the assertion does not depend on the clock moving. Within
# one second a first-seen that is silently RESET is identical to one carried
# forward, and the first version of this check passed for exactly that reason,
# measured, by mutation.
sed -i 's/^FAILED=1 [0-9]* alpha.txt$/FAILED=1 1000000000 alpha.txt/' \
  "$(failed_file docs)"
[ "$(_since docs alpha.txt)" = 1000000000 ] || fail "could not backdate alpha"
_a1=1000000000
record_failures docs 2 "$T/ab"
[ "$(_streak docs alpha.txt)" = 2 ] \
  || fail "alpha's streak did not advance: $(_streak docs alpha.txt)"
[ "$(_since docs alpha.txt)" = "$_a1" ] \
  || fail "alpha's first-seen moved while it kept failing: it reads
  $(_since docs alpha.txt), so a chronic fault would report as brand new"

# THE FLAPPING CASE, and the whole reason for this shape. A THIRD path joins.
# alpha and beta are unaffected: their history is theirs.
printf 'Failed [alpha.txt]: E\nFailed [beta.txt]: E\nFailed [gamma.txt]: E\n' \
  > "$T/abg"
record_failures docs 2 "$T/abg"
[ "$(_streak docs alpha.txt)" = 3 ] \
  || fail "a path JOINING the failure set reset alpha's streak to
  $(_streak docs alpha.txt). That is the bug: a shifting set meant no path ever
  accumulated a streak, so nothing was ever unwedged."
[ "$(_since docs alpha.txt)" = "$_a1" ] \
  || fail "a path joining reset alpha's first-seen, so a chronic fault would
  report as brand new forever"
[ "$(_streak docs gamma.txt)" = 1 ] \
  || fail "the newly-joined path did not start at 1"

# ...and a path LEAVING is equally none of alpha's business.
record_failures docs 2 "$T/ab"
[ "$(_streak docs alpha.txt)" = 4 ] \
  || fail "a path LEAVING the set reset alpha's streak to
  $(_streak docs alpha.txt)"
[ -z "$(_rec docs gamma.txt)" ] \
  || fail "a path that stopped failing is still in the record; its absence is
  what settled_paths reads to sweep its temps"

# A path that SETTLES and comes back starts over: its streak measures a
# CONSECUTIVE run, and it demonstrably synced in between.
record_failures docs 2 "$T/abg"
[ "$(_streak docs gamma.txt)" = 1 ] \
  || fail "a path that settled and returned did not restart its streak"

# LAST moves on every observation, or nothing can tell a live fault from a
# stale record.
_l1=$(failed_get docs LAST)
sed -i "s/^LAST=.*/LAST=1000000000/" "$(failed_file docs)"
record_failures docs 2 "$T/abg"
[ "$(failed_get docs LAST)" != 1000000000 ] \
  || fail "LAST did not move on a fresh observation"
[ -n "$_l1" ] || fail "no LAST recorded at all"

# A RECORD FROM AN OLDER VERSION had bare paths and no counters. Read it as a
# first sighting rather than discarding it: an upgrade mid-fault should lose the
# history, not the fault.
printf 'LAST=5\nRC=2\nFAILED=legacy path.txt\n' > "$(failed_file docs)"
[ "$(failed_paths docs)" = 'legacy path.txt' ] \
  || fail "a pre-counter record was not readable: $(failed_paths docs)"
[ "$(_streak docs 'legacy path.txt')" = 1 ] \
  || fail "a pre-counter record did not read as a first sighting"

# ----------------------------------------------------------------- part 4 ----
# run_teed returns the COMMAND's status, not tee's, and still streams.
run_teed "$T/cap" sh -c 'echo streamed; exit 7' >"$T/streamed" 2>&1; _rc=$?
[ "$_rc" = 7 ] \
  || fail "run_teed returned $_rc, not the command's 7 (\$? after a pipeline is
  tee's, which is the whole reason the status is smuggled through a file)"
grep -qx streamed "$T/cap" || fail "run_teed did not capture the output"
grep -qx streamed "$T/streamed" \
  || fail "run_teed did not also STREAM the output; the journal must still see
  unison's failures as they happen, not in one lump an hour later"
# An empty capture path runs the command untouched.
run_teed "" sh -c 'exit 5'; [ "$?" = 5 ] \
  || fail "run_teed with no capture file lost the command's status"

# ----------------------------------------------------------------- part 5 ----
# THE REPORT. check must NAME the paths, and it must do so even when the unit
# SUCCEEDED: unison exits 2 only for a transfer failure, so a profile can be
# green overall with a path quietly stuck. A verdict line with nothing under it
# is the "presence is not function" trap in a new place.
record_failures docs 2 "$T/out"
_rep=$(report_failed_paths docs); _reprc=$?
[ "$_reprc" = 0 ] \
  || fail "report_failed_paths returned $_reprc; a trailing false test becoming
  the function's status is how an apply once aborted under set -e"
case $_rep in
  *"3 path(s) failing"*) : ;;
  *) fail "report_failed_paths did not name the count: $_rep" ;;
esac
case $_rep in
  *"sub/Fenix Watchface - tuned.psp"*) : ;;
  *) fail "report_failed_paths did not name the space-containing path: $_rep" ;;
esac

# It truncates rather than dumping an unbounded list into a check.
: > "$T/many"
i=1; while [ "$i" -le 9 ]; do printf 'Failed [p%s.txt]: E\n' "$i" >>"$T/many"
  i=$((i + 1)); done
record_failures docs 2 "$T/many"
_rep=$(report_failed_paths docs)
case $_rep in
  *"and 4 more"*) : ;;
  *) fail "report_failed_paths did not truncate 9 paths: $_rep" ;;
esac
[ "$(printf '%s\n' "$_rep" | grep -c '^           p')" = 5 ] \
  || fail "report_failed_paths listed the wrong number of sample paths"

# Nothing recorded, nothing printed.
rm -f "$(failed_file docs)"
[ -z "$(report_failed_paths docs)" ] \
  || fail "report_failed_paths printed something with no record"

# AND IT MUST FIRE UNDER A GREEN VERDICT TOO. unison exits 2 only for a
# TRANSFER failure, so a unit can be Result=success while paths sit stuck,
# and a [OK] line with a stuck path hidden under it is exactly the
# presence-is-not-function trap this project keeps rediscovering. A stub that
# reports a healthy unit is the only way to reach that branch.
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
  *ExecMainStartTimestamp*) echo "Fri 2026-09-25 12:00:00 EDT" ;;
  *ExecMainStatus*)         echo 0 ;;
  *Result*)                 echo success ;;
esac
exit 0
EOF
chmod +x "$T/bin/systemctl"
record_failures docs 2 "$T/out"
CHECK_DRIFT=; CHECK_FAULT=
_ok=$(PATH="$T/bin:$PATH" check_profile_outcome docs); _okrc=$?
# It must REPORT the unit's own last run honestly...
case $_ok in
  *'[OK]'*'last run: success'*) : ;;
  *) fail "expected an [OK] line for the unit's successful last run: $_ok" ;;
esac
# ...and still FAIL on the paths stuck under it. This used to print them and
# return SUCCESS, which is the presence-is-not-function trap: a green verdict
# over a path that has not synced in days.
[ "$_okrc" != 0 ] \
  || fail "check_profile_outcome returned success for a unit whose last run
  succeeded while paths were still failing under it"
case $_ok in
  *'[FAULT]'*) : ;;
  *) fail "stuck paths under a green unit were not reported as a FAULT: $_ok" ;;
esac
case $_ok in
  *"3 path(s) failing"*) : ;;
  *) fail "check said nothing about the 3 paths still failing: $_ok" ;;
esac
# AND IT IS A FAULT, NOT DRIFT, which is the whole point of the classification:
# no amount of re-provisioning makes a stuck path sync.
PATH="$T/bin:$PATH" check_profile_outcome docs >/dev/null 2>&1 || :
[ -n "$CHECK_FAULT" ] || fail "stuck paths did not set the FAULT class"
[ -z "$CHECK_DRIFT" ] \
  || fail "stuck paths were classified as DRIFT, which would send an integrator
  round a re-provision loop that cannot converge"
check_verdict 1; _vd=$?
[ "$_vd" = "$EX_FAULT" ] \
  || fail "the verdict for stuck paths was $_vd, expected EX_FAULT ($EX_FAULT)"
CHECK_DRIFT=; CHECK_FAULT=

# ----------------------------------------------------------------- part 6 ----
# END TO END, with REAL unison actually failing. A parse validated only against
# a canned sample is a parse validated against my own idea of the output; this
# is the assertion that charon and unison agree in practice, capture and all.
# Everything from here needs REAL unison, and that includes the unit-level
# parts below, which is worth saying plainly: a box without unison exercises
# only parts 1-5, and the message says so rather than reporting a full pass.
command -v unison >/dev/null 2>&1 || {
  pass "parse, gate, SINCE, report only (no unison: parts 6-12 skipped)"
  exit 0
}
for s in systemctl systemd-run mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    CHARON_STATE=$T/state UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg \
    sh "$HERE/bin/charon" "$@"
}
rm -rf "$T/state/failed"
printf 'first\n' > "$T/src/D/settled.txt"
_c install >/dev/null 2>&1 || fail "install failed (end-to-end setup)"
_c sync docs >/dev/null 2>&1
[ -f "$T/cache/D/settled.txt" ] \
  || fail "the baseline pass did not populate the cache, so the failure below
  would not be isolating anything"
[ -z "$(failed_paths docs)" ] \
  || fail "a clean baseline pass recorded failed paths: $(failed_paths docs)"

# Now make the propagation genuinely fail, on a name with spaces, by taking
# write permission off the destination directory.
printf 'new\n' > "$T/src/D/Fenix Watchface - tuned.psp"
chmod a-w "$T/cache/D"
_c sync docs >/dev/null 2>&1; _syncrc=$?
chmod u+w "$T/cache/D"
[ "$_syncrc" != 0 ] \
  || fail "the pass with an unwritable destination SUCCEEDED, so the recording
  assertion below would pass for the wrong reason"
_e2e=$(failed_paths docs)
[ -n "$_e2e" ] \
  || fail "a real failing unison pass recorded NO failed paths: charon and
  unison disagree about the output format, which is exactly what part 1's
  canned sample cannot catch"
# THE PATH IS RELATIVE TO THE PROFILE'S ROOTS, not to the source root: charon
# sets `root = <mount>/<subtree>`, so the subtree is NOT part of what unison
# reports. Pinned here because the surgical cleanup built on this has to join
# the path back onto a root to find a crumb, and prefixing the subtree twice
# would look for it in a directory that does not exist, a cleanup that
# silently finds nothing is the worst kind.
printf '%s\n' "$_e2e" | grep -qx 'Fenix Watchface - tuned.psp' \
  || fail "the recorded path is not the one that failed; got: $_e2e"
printf '%s\n' "$_e2e" | grep -q '^D/' \
  && fail "the recorded path carries the SUBTREE prefix; unison reports
  relative to its roots, and charon's roots already include the subtree"

# ----------------------------------------------------------------- part 7 ----
# THE SETTLE DIFF. A path that WAS failing and is not any more has settled;
# anything still failing has not. This is the only moment the orphan condition
# is observable, which is why cleanup is keyed on it rather than on failure.
rm -rf "$T/state/failed"
record_failures docs 2 "$T/out"    # 3 paths
printf '%s\n' 'plain.txt' > "$T/newset"
_st=$(settled_paths docs "$T/newset")
_wantst='sub/Fenix Watchface - tuned.psp
sub/second file.png'
[ "$_st" = "$_wantst" ] || fail "settled_paths got:
$_st
want:
$_wantst"
# Still failing on everything: nothing has settled.
parse_unison_failures "$T/out" > "$T/samenow"
[ -z "$(settled_paths docs "$T/samenow")" ] \
  || fail "settled_paths called a path settled while it was STILL failing,
  which would delete a temp that the next pass still needs to resume from"
# No prior record, nothing settled (a first-ever pass must not claim anything).
rm -rf "$T/state/failed"
[ -z "$(settled_paths docs "$T/newset")" ] \
  || fail "settled_paths invented settled paths with no prior record"

# ----------------------------------------------------------------- part 8 ----
# THE SURGICAL REMOVAL, matched LITERALLY. The names here are the adversarial
# ones: a glob-based matcher would silently miss every one of them, and a silent
# miss in a cleanup is the kind nobody notices.
mkdir -p "$T/mnt/d" "$T/cch/d"
_mk() { printf 'x' > "$1"; }
_mk "$T/mnt/d/.unison.odd[name.png.aaa111.unison.tmp"
_mk "$T/cch/d/.unison.odd[name.png.bbb222.unison.tmp"
_mk "$T/mnt/d/.unison.star*name.png.ccc333.unison.tmp"
_mk "$T/mnt/d/.unison.with spaces.psp.ddd444.unison.tmp"
_mk "$T/mnt/d/.unison.other.png.eee555.unison.tmp"   # a DIFFERENT path
_mk "$T/mnt/d/real.png"                              # real content
sweep_path_crumbs "$T/mnt" "$T/cch" 'd/odd[name.png'
[ -e "$T/mnt/d/.unison.odd[name.png.aaa111.unison.tmp" ] \
  && fail "a crumb for a name containing '[' was not removed: a glob matcher
  reads '[' as a character class and silently matches nothing"
[ -e "$T/cch/d/.unison.odd[name.png.bbb222.unison.tmp" ] \
  && fail "the CACHE-side crumb survived; both replicas must be cleaned"
sweep_path_crumbs "$T/mnt" "$T/cch" 'd/star*name.png'
[ -e "$T/mnt/d/.unison.star*name.png.ccc333.unison.tmp" ] \
  && fail "a crumb for a name containing '*' was not removed"
sweep_path_crumbs "$T/mnt" "$T/cch" 'd/with spaces.psp'
[ -e "$T/mnt/d/.unison.with spaces.psp.ddd444.unison.tmp" ] \
  && fail "a crumb for a name containing spaces was not removed"
# AND IT TOUCHED NOTHING ELSE. These are the controls: another path's crumb and
# a real file. A matcher that over-reaches would take both.
[ -f "$T/mnt/d/.unison.other.png.eee555.unison.tmp" ] \
  || fail "sweep_path_crumbs removed ANOTHER path's crumb"
[ -f "$T/mnt/d/real.png" ] \
  || fail "sweep_path_crumbs removed real content"
# A missing directory is not an error.
sweep_path_crumbs "$T/mnt" "$T/cch" 'nope/gone.txt' \
  || fail "sweep_path_crumbs failed on a path whose directory does not exist"

# ----------------------------------------------------------------- part 9 ----
# END TO END: a path fails, strands a crumb, then settles, and the crumb goes
# on the very next pass, with no age gate involved, because settling is proof
# rather than a guess.
command -v unison >/dev/null 2>&1 || {
  pass "parse, gate, SINCE, report, settle diff and surgical removal"
  exit 0
}
_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    CHARON_STATE=$T/state UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg \
    sh "$HERE/bin/charon" "$@"
}
# Self-contained: parts 7 and 8 overwrote the record with canned data, so
# establish a REAL failing path again rather than leaning on part 6.
rm -rf "$T/state/failed"
printf 'again\n' > "$T/src/D/settle me.psp"
chmod a-w "$T/cache/D"
_c sync docs >/dev/null 2>&1
chmod u+w "$T/cache/D"
failed_paths docs | grep -qx 'settle me.psp' \
  || fail "the setup pass did not record the failing path; got:
  $(failed_paths docs)"
# Plant a crumb for it, in the DESTINATION directory. Its hash deliberately is
# not one unison would compute, so unison itself will not consume it: what
# removes it has to be charon's own settle cleanup.
CRUMB="$T/cache/D/.unison.settle me.psp.f00d99.unison.tmp"
printf 'partial' > "$CRUMB"
[ -f "$CRUMB" ] || fail "could not plant the crumb"
# Destination writable again: this pass propagates, the path settles, and its
# crumb becomes litter by proof rather than by age.
_c sync docs >/dev/null 2>&1
[ -z "$(failed_paths docs)" ] \
  || fail "the recovery pass still reports failures: $(failed_paths docs)"
[ -e "$CRUMB" ] \
  && fail "the crumb for a SETTLED path survived the pass that settled it;
  the surgical cleanup did not fire (it is the whole point of parsing the
  output at all)"

# And the trust gate reaches this half too: with no prior record there is
# nothing to settle, so a pass must not go hunting.
printf 'orphan' > "$T/cache/D/.unison.unrelated.f00d99.unison.tmp"
_c sync docs >/dev/null 2>&1
[ -f "$T/cache/D/.unison.unrelated.f00d99.unison.tmp" ] \
  || fail "a pass deleted a crumb for a path that was never in the failure
  record; the surgical half must only ever act on a path it watched settle,
  and the blind sweep is what handles everything else"

# ---------------------------------------------------------------- part 10 ----
# THE TRUST GATE, ON THE DELETING HALF. This is the one way the whole design
# could destroy something: an INTERRUPTED pass prints a truncated failure list,
# so a path that is still failing is simply absent from it, and reading that
# absence as "settled" deletes a temp the next pass needs to resume from.
#
# A unison that exits 3 ("fatal error or execution interrupted") printing NO
# failures is exactly that shape. With the gate, nothing happens. Without it,
# every recorded path looks settled and its crumb goes.
rm -rf "$T/state/failed"
printf 'more\n' > "$T/src/D/keep my temp.psp"
chmod a-w "$T/cache/D"
_c sync docs >/dev/null 2>&1
chmod u+w "$T/cache/D"
failed_paths docs | grep -qx 'keep my temp.psp' \
  || fail "setup for the interrupted-pass case recorded nothing"
KEEP="$T/cache/D/.unison.keep my temp.psp.beef01.unison.tmp"
printf 'partial' > "$KEEP"
_before=$(failed_paths docs)

cat > "$T/bin/unison" <<'EOF'
#!/bin/sh
# An INTERRUPTED unison: says nothing about failures, exits 3.
exit 3
EOF
chmod +x "$T/bin/unison"
_c sync docs >/dev/null 2>&1
rm -f "$T/bin/unison"

[ -f "$KEEP" ] \
  || fail "an INTERRUPTED pass (unison exit 3, empty failure list) deleted the
  temp for a path that is still failing. Absence from a truncated list is not
  evidence that a path settled, and that temp is the resume point."
[ "$(failed_paths docs)" = "$_before" ] \
  || fail "an interrupted pass overwrote the failure record with its own
  truncated list; got: $(failed_paths docs)"

# ---------------------------------------------------------------- part 11 ----
# UNWEDGING: the fault that nothing could clear.
#
# A profile that fails the identical propagation every pass stays failed
# forever: the attempt cannot succeed, so unison never commits the archive, so
# the next pass tries exactly the same thing. That ran for four hours on
# 2026-09-24 and a human had to break it by hand. The one safe intervention is
# to drop the transfer temps for the failing paths: a temp is never content, it
# is measurably not helping after N tries, and a stranded one is itself enough
# to cause this error.
#
# PER PATH, because the streak is per path. A path reaches the threshold on its
# own history, whatever its neighbours are doing.
rm -rf "$T/state/failed"
: > "$T/canned"
printf 'Failed [wedged one.psp]: Destination updated\n' >> "$T/canned"
printf 'Failed [wedged two.png]: Destination updated\n' >> "$T/canned"
mkdir -p "$T/cache/D" "$T/src/D"
W1="$T/cache/D/.unison.wedged one.psp.dead01.unison.tmp"
W2="$T/src/D/.unison.wedged two.png.dead02.unison.tmp"

# Passes 1 and 2: the streaks build and NOTHING is touched. Intervening on the
# first failure would destroy a live resume point, which is the whole reason
# this waits.
printf 'partial' > "$W1"; printf 'partial' > "$W2"
for n in 1 2; do
  record_failures docs 2 "$T/canned"
  [ "$(_streak docs 'wedged one.psp')" = "$n" ] \
    || fail "after pass $n the streak reads $(_streak docs 'wedged one.psp')"
  [ -z "$(wedged_paths docs 3)" ] \
    || fail "a path reached the threshold after only $n failure(s)"
  unwedge_profile docs >/dev/null 2>&1
  [ -f "$W1" ] && [ -f "$W2" ] \
    || fail "the temps were dropped after only $n failure(s); a temp that has
    not had its chances is a live resume point and must be left alone"
done

# Pass 3 crosses the default threshold: both temps go, on BOTH replicas, and the
# failure record is untouched (this clears the obstacle, it does not pretend the
# fault is over).
record_failures docs 2 "$T/canned"
[ "$(_streak docs 'wedged one.psp')" = 3 ] || fail "the streak did not reach 3"
[ "$(wedged_paths docs 3 | wc -l)" = 2 ] \
  || fail "wedged_paths did not name both paths at the threshold"
_uw=$(unwedge_profile docs 2>&1)
[ -e "$W1" ] && fail "the cache-side temp survived the unwedge"
[ -e "$W2" ] && fail "the mount-side temp survived the unwedge"
[ -n "$(failed_paths docs)" ] \
  || fail "the unwedge cleared the failure RECORD; it removes the obstacle, it
  does not decide the fault is over: only a real pass can say that"
case $_uw in
  *"3 passes running"*) : ;;
  *) fail "the unwedge said nothing a human could act on: $_uw" ;;
esac
# It must SAY it is intervening. This deletes from the user's remote on its own
# initiative, so silence would be the wrong shape entirely.
printf '%s\n' "$_uw" | grep -q 'wedged one.psp' \
  || fail "the unwedge did not name the paths it acted on: $_uw"

# Pass 4: ONCE per path. Acting again would be a no-op that logged every pass,
# and a warning that fires every time is one nobody reads.
printf 'partial' > "$W1"
record_failures docs 2 "$T/canned"
[ "$(_streak docs 'wedged one.psp')" = 4 ] || fail "the streak did not reach 4"
unwedge_profile docs >/dev/null 2>&1
[ -f "$W1" ] \
  || fail "the unwedge fired again past the threshold; it acts once per path"

# A PATH THAT SETTLES AND RETURNS starts over, because its streak measures a
# CONSECUTIVE run and it demonstrably synced in between.
printf 'Failed [wedged two.png]: Destination updated\n' > "$T/only2"
record_failures docs 2 "$T/only2"
record_failures docs 2 "$T/canned"
[ "$(_streak docs 'wedged one.psp')" = 1 ] \
  || fail "a path that settled and returned did not restart its streak"

# AND THE FLAPPING CASE REACHES THE THRESHOLD NOW. Under the old set-level
# counter this sequence could never unwedge anything: the set changes on every
# pass, so the count reset every pass. 'wedged two.png' fails throughout and
# must be acted on regardless of what the other path does.
rm -rf "$T/state/failed"
printf 'partial' > "$W2"
printf 'Failed [wedged two.png]: E\nFailed [noise a.txt]: E\n' > "$T/f1"
printf 'Failed [wedged two.png]: E\n' > "$T/f2"
printf 'Failed [wedged two.png]: E\nFailed [noise b.txt]: E\n' > "$T/f3"
for f in "$T/f1" "$T/f2" "$T/f3"; do
  record_failures docs 2 "$f"
  unwedge_profile docs >/dev/null 2>&1
done
[ "$(_streak docs 'wedged two.png')" = 3 ] \
  || fail "with the set shifting every pass, the persistent path's streak reads
  $(_streak docs 'wedged two.png') instead of 3. This is the flapping bug: the
  chronic fault was invisible and could never be unwedged."
[ -e "$W2" ] \
  && fail "the persistent path's temp survived a shifting-set wedge, so the
  unwedge still cannot reach the one path that is genuinely stuck"

# AN INTERRUPTED PASS MUST NOT ADVANCE IT. This is what makes the streak mean
# "tried properly and failed again" rather than "was cut short again", and it is
# what keeps a genuinely resuming large transfer from ever reaching the
# threshold.
rm -rf "$T/state/failed"
record_failures docs 2 "$T/canned"
_k=$(_streak docs 'wedged one.psp')
for rc in 3 124 137; do
  record_failures docs "$rc" "$T/canned"
  [ "$(_streak docs 'wedged one.psp')" = "$_k" ] \
    || fail "an interrupted pass (rc $rc) advanced the streak to
    $(_streak docs 'wedged one.psp'); a resuming transfer would then be
    unwedged out from under itself"
done

# THE THRESHOLD IS THE USER'S, and 0 disables the whole thing.
printf 'UNWEDGE_AFTER=0\n' > "$CFG/charon.conf"
rm -rf "$T/state/failed"; printf 'partial' > "$W1"; printf 'partial' > "$W2"
for n in 1 2 3 4 5; do
  record_failures docs 2 "$T/canned"
  unwedge_profile docs >/dev/null 2>&1
done
[ -f "$W1" ] || fail "UNWEDGE_AFTER=0 did not disable the unwedge"
printf 'UNWEDGE_AFTER=2\n' > "$CFG/charon.conf"
rm -rf "$T/state/failed"; printf 'partial' > "$W1"; printf 'partial' > "$W2"
record_failures docs 2 "$T/canned"
unwedge_profile docs >/dev/null 2>&1
[ -f "$W1" ] || fail "UNWEDGE_AFTER=2 fired on the first failure"
record_failures docs 2 "$T/canned"
unwedge_profile docs >/dev/null 2>&1
[ -e "$W1" ] && fail "UNWEDGE_AFTER=2 did not fire on the second failure"
rm -f "$CFG/charon.conf"

# AND IT MUST NOT CLAIM TO INTERVENE WHEN IT CANNOT. Dropping a temp is the only
# lever charon has, and it does not fit every wedge: a SCAN failure (an
# unreadable file, a fifo) has no temp at all. Announcing an intervention and
# then silently doing nothing would be the worst of both; saying "there is
# nothing I can do" is itself the useful signal.
rm -rf "$T/state/failed"
printf 'Failed [no temp here.psp]: Destination updated\n' > "$T/notemp"
for n in 1 2 3; do record_failures docs 2 "$T/notemp"; done
[ "$(_streak docs 'no temp here.psp')" = 3 ] || fail "no-temp streak setup"
_nt=$(unwedge_profile docs 2>&1)
case $_nt in
  *"NOTHING it can do"*) : ;;
  *) fail "with no temps to drop the unwedge still announced an intervention
     it could not make: $_nt" ;;
esac
case $_nt in
  *"no temp here.psp"*) : ;;
  *) fail "the no-temp warning did not name the wedged path: $_nt" ;;
esac
# ...and when there IS something, it says how many rather than implying all.
printf 'partial' > "$T/cache/D/.unison.no temp here.psp.f00d.unison.tmp"
rm -rf "$T/state/failed"
for n in 1 2 3; do record_failures docs 2 "$T/notemp"; done
_yt=$(unwedge_profile docs 2>&1)
case $_yt in
  *"dropping 1 transfer temp"*) : ;;
  *) fail "the unwedge did not report HOW MANY temps it dropped: $_yt" ;;
esac
[ -e "$T/cache/D/.unison.no temp here.psp.f00d.unison.tmp" ] \
  && fail "the unwedge reported dropping a temp and left it there"

# The summary reports the WORST streak and the OLDEST first-seen, not whichever
# path happens to be last: a newly-joined path must not reset its story.
#
# The record is built DIRECTLY so the worst and oldest are deliberately NOT
# last. Driving it through record_failures put them last by accident (paths are
# stored sorted), and a summary that simply took the final record passed,
# measured, by mutation, twice.
rm -rf "$T/state/failed"; mkdir -p "$T/state/failed"
_now=$(date +%s)
{ printf 'LAST=%s\nRC=2\n' "$_now"
  printf 'FAILED=9 %s aaa chronic.psp\n' "$((_now - 7200))"
  printf 'FAILED=1 %s zzz newcomer.txt\n' "$_now"
} > "$(failed_file docs)"
_fs=$(failed_summary docs "$_now")
case $_fs in
  *"2 path(s) failing"*) : ;;
  *) fail "the summary miscounted: $_fs" ;;
esac
case $_fs in
  *"worst 9 passes running"*) : ;;
  *) fail "the summary did not report the WORST streak (9, on the path that is
     not last); it said: $_fs" ;;
esac
case $_fs in
  *"oldest first seen 2h ago"*) : ;;
  *) fail "the summary did not report the OLDEST first-seen (2h, on the path
     that is not last); it said: $_fs" ;;
esac
# A lone first sighting says neither: "1 passes running" is noise.
{ printf 'LAST=%s\nRC=2\n' "$_now"
  printf 'FAILED=1 %s only.txt\n' "$_now"
} > "$(failed_file docs)"
case "$(failed_summary docs "$_now")" in
  *"passes running"*) fail "the summary claims a streak after ONE failure" ;;
esac

# ---------------------------------------------------------------- part 12 ----
# THE WHOLE LOOP, COMPOSED, WITH REAL UNISON. Part 11 proves the state machine
# against canned output and part 6 proves the parse against reality; this is the
# one that proves they work TOGETHER over consecutive real failing passes, which
# is the only form the 2026-09-24 fault ever took.
#
# The wedge is induced with an unwritable destination directory, the one
# induction measured to produce a real REPEATING `Failed [path]:` at rc 2. The
# removal itself cannot succeed there (rm needs a writable directory, and charon
# says so loudly when it cannot); part 11 covers removal. What this pins is the
# TIMING: the streak builds, the intervention happens ONCE, and it lands at the
# threshold rather than on the first failure or on every pass.
rm -rf "$T/state/failed" "$T/uni" "$T/src/D" "$T/cache/D"
mkdir -p "$T/uni" "$T/src/D" "$T/cache/D"
printf 'base\n' > "$T/src/D/keep.txt"
_c install >/dev/null 2>&1 || fail "install failed (part 12 setup)"
_c sync docs >/dev/null 2>&1
[ -f "$T/cache/D/keep.txt" ] || fail "the part 12 baseline did not populate"
printf 'content\n' > "$T/src/D/wedge me.psp"
# A temp planted BEFORE the directory goes read-only, so the intervention has
# something real to find. Its removal cannot succeed in an unwritable directory
# and charon says so loudly; part 11 covers the removal itself. What this pins
# is the TIMING and the per-path counting over real passes.
printf 'partial' > "$T/cache/D/.unison.wedge me.psp.c0ffee.unison.tmp"
chmod a-w "$T/cache/D"
_fired=0
_at=never
for n in 1 2 3 4; do
  _e=$(_c sync docs 2>&1 >/dev/null) || :
  _k=$(_streak docs 'wedge me.psp')
  if [ "$_k" != "$n" ]; then
    chmod u+w "$T/cache/D"
    fail "after real failing pass $n the streak reads '$_k', not $n"
  fi
  # Grep the phrase unique to the INTERVENTION, not one the fault summary also
  # prints: the summary says "worst N passes running" too, so a looser match
  # would count every pass from 2 up.
  case $_e in
    *"transfer temp(s) so the next pass"*) _fired=$((_fired + 1)); _at=$n ;;
  esac
done
chmod u+w "$T/cache/D"
[ "$_fired" = 1 ] \
  || fail "the unwedge fired $_fired times across 4 real failing passes; once
  per fault, or it is a warning nobody reads"
[ "$_at" = 3 ] \
  || fail "the unwedge fired at pass $_at, not at the threshold of 3"
failed_paths docs | grep -qx 'wedge me.psp' \
  || fail "the composed run recorded the wrong path: $(failed_paths docs)"

pass "unison's failed paths parsed, gated, dated, reported, settled, unwedged"
