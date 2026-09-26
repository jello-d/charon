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
#   1. THE PARSE, against real unison output, including a path with spaces --
#      every name that has ever caused trouble in this project has had spaces.
#   2. THE TRUST GATE. A list is only complete if unison reached its own
#      verdict (exit 0/1/2). Exit 3 is "fatal error OR EXECUTION INTERRUPTED"
#      and charon's own `timeout` kill gives 124/137. A truncated list recorded
#      as fact is how the cleanup built on top of this could delete a temp that
#      a resume still needs, so the guard is asserted from both sides.
. "$(dirname "$0")/lib.sh"
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
# this test unchanged -- measured, by mutation, and it did.
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

# A trusted run with NO failures CLEARS the record, so its absence is the
# signal that the profile is clean.
: > "$T/clean"
record_failures docs 0 "$T/clean"
[ -z "$(failed_paths docs)" ] \
  || fail "a clean pass did not clear the failed-path record"
[ ! -f "$(failed_file docs)" ] \
  || fail "a clean pass left the record FILE behind; its absence is the signal"

# ----------------------------------------------------------------- part 3 ----
# SINCE means what it says: it survives an UNCHANGED set and resets on a
# changed one, because a different set of paths is a new fault rather than a
# continuation of the old one.
record_failures docs 2 "$T/out"
_s1=$(failed_get docs SINCE)
[ -n "$_s1" ] || fail "no SINCE recorded"
# Backdate it, then re-record the IDENTICAL set: SINCE must be preserved.
sed -i "s/^SINCE=.*/SINCE=1000000000/" "$(failed_file docs)"
record_failures docs 2 "$T/out"
[ "$(failed_get docs SINCE)" = 1000000000 ] \
  || fail "SINCE was reset by re-recording an IDENTICAL failure set, so
  'failing since' would always read as 'just now'"
# LAST must move even when SINCE does not, or nothing can tell a live fault
# from a stale record.
[ "$(failed_get docs LAST)" != 1000000000 ] \
  || fail "LAST did not move on a fresh observation"
# A DIFFERENT set resets SINCE.
printf 'Failed [somewhere/else.txt]: Error\n' > "$T/out3"
record_failures docs 2 "$T/out3"
[ "$(failed_get docs SINCE)" != 1000000000 ] \
  || fail "SINCE survived a CHANGED failure set, overstating how long the
  current fault has been true"

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
# SUCCEEDED -- unison exits 2 only for a transfer failure, so a profile can be
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
# TRANSFER failure, so a unit can be Result=success while paths sit stuck --
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
_ok=$(PATH="$T/bin:$PATH" check_profile_outcome docs); _okrc=$?
[ "$_okrc" = 0 ] \
  || fail "check_profile_outcome returned $_okrc for a unit whose last run
  SUCCEEDED; stuck paths are not the unit failing"
case $_ok in
  *'[OK]'*) : ;;
  *) fail "expected an [OK] verdict for a successful unit: $_ok" ;;
esac
case $_ok in
  *"3 path(s) failing"*) : ;;
  *) fail "check said [OK] and said NOTHING about the 3 paths still failing
     under it: $_ok" ;;
esac

# ----------------------------------------------------------------- part 6 ----
# END TO END, with REAL unison actually failing. A parse validated only against
# a canned sample is a parse validated against my own idea of the output; this
# is the assertion that charon and unison agree in practice, capture and all.
command -v unison >/dev/null 2>&1 || {
  pass "parse, trust gate, SINCE and report (end-to-end skipped: no unison)"
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
# would look for it in a directory that does not exist -- a cleanup that
# silently finds nothing is the worst kind.
printf '%s\n' "$_e2e" | grep -qx 'Fenix Watchface - tuned.psp' \
  || fail "the recorded path is not the one that failed; got: $_e2e"
printf '%s\n' "$_e2e" | grep -q '^D/' \
  && fail "the recorded path carries the SUBTREE prefix; unison reports
  relative to its roots, and charon's roots already include the subtree"

pass "unison's failed paths parsed, gated, dated and reported, end to end"
