#!/bin/sh
# audit.t - the remote audit: duplicate names and contentless objects.
#
# WHY THIS EXISTS. On 2026-10-04 the Drive behind this fleet held 539 paths with
# TWO objects each: the real file, and one whose size rclone reports as -1,
# meaning no content stream. Drive permits duplicate names and a FUSE mount must
# present ONE object per name, so the file's apparent content FLIPS between
# passes and unison correctly reads both replicas as diverged. That manufactured
# 283 conflicts across three nodes in a day, and charon could not see any of it:
# nothing in any check asked the remote whether a path has two objects.
#
# Three separable claims, tested separately:
#   the PARSER   given a listing, does it name the right paths
#   the RECORD   is a partial listing refused rather than written
#   the CHECK    does a finding become a FAULT, and an absent audit a WARN
. "$(dirname "$0")/harness_lib"
harness_init audit

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_STATE=$T/state
export CHARON_TRAITS_DIR=$T/state/traits
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/state" \
         "$T/mnt/Docs" "$T/cache/Docs"

cat > "$CFG/sources.d/gd.conf" <<EOF
PROVIDER=rclone
REMOTE=gd
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
cat > "$CFG/sources.d/byo.conf" <<EOF
PROVIDER=none
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=gd:Docs\n' > "$CFG/profiles.d/docs.conf"

#### THE PARSER, against canned rclone JSON, with no remote anywhere ####
# Pure by design so the interesting shapes are reachable without a network: a
# clean listing, a duplicated path, a contentless object, and the pair together.
CHARON_LIB_ONLY=1
# shellcheck disable=SC1090
. "$CHARON_LIBEXEC/charon-source"

_parse() { printf '%s' "$1" | audit_report "$2"; }

_clean='[{"Path":"a.txt","Name":"a.txt","Size":10},
         {"Path":"d/b.txt","Name":"b.txt","Size":20}]'
out=$(_parse "$_clean" Docs)
[ -z "$out" ] || fail "a clean listing produced findings: $out"

_dup='[{"Path":"a.txt","Name":"a.txt","Size":10},
       {"Path":"a.txt","Name":"a.txt","Size":10}]'
out=$(_parse "$_dup" Docs)
printf '%s\n' "$out" | grep -qx 'DUPE=2 Docs/a.txt' \
  || fail "a duplicated path was not reported with its count and full path:
$out"
printf '%s\n' "$out" | grep -q '^NOCONTENT=' \
  && fail "two REAL objects were called contentless: $out" || :

_neg='[{"Path":"a.txt","Name":"a.txt","Size":-1}]'
out=$(_parse "$_neg" Docs)
printf '%s\n' "$out" | grep -qx 'NOCONTENT=Docs/a.txt' \
  || fail "an object with Size -1 was not reported: $out"
printf '%s\n' "$out" | grep -q '^DUPE=' \
  && fail "a single object was called a duplicate: $out" || :

# the real-world shape: the pair that caused the incident
_both='[{"Path":"x.xlsx","Name":"x.xlsx","Size":28226},
        {"Path":"x.xlsx","Name":"x.xlsx","Size":-1}]'
out=$(_parse "$_both" Docs)
printf '%s\n' "$out" | grep -qx 'DUPE=2 Docs/x.xlsx' \
  || fail "the real incident shape was not flagged as a duplicate: $out"
printf '%s\n' "$out" | grep -qx 'NOCONTENT=Docs/x.xlsx' \
  || fail "the contentless half of the pair was not flagged: $out"

# the prefix is joined, because the listing is relative to the subtree and a
# bare name would send a reader looking in the wrong directory
out=$(_parse "$_dup" 'Media/Images')
printf '%s\n' "$out" | grep -q 'Media/Images/a.txt' \
  || fail "the subtree prefix was not joined back onto the path: $out"
# ...and with no prefix the path stands alone rather than gaining a slash
out=$(_parse "$_dup" '')
printf '%s\n' "$out" | grep -qx 'DUPE=2 a.txt' \
  || fail "an empty prefix produced a malformed path: $out"
unset CHARON_LIB_ONLY

#### THE RECORD + THE VERB, with a stubbed rclone ####
cat > "$T/bin/rclone" <<'STUB'
#!/bin/sh
case "$1" in
  lsjson)
    [ -n "${AUDIT_FAIL:-}" ] && exit 7
    cat "${AUDIT_JSON:?}" ;;
  listremotes) printf 'gd:\n' ;;
esac
exit 0
STUB
chmod +x "$T/bin/rclone"
for s in unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
# systemctl must answer list-unit-files from the unit dir, not exit 0 printing
# nothing. A silent stub leaves check reporting DRIFT ("charon-sync@.service not
# registered") for a reason unrelated to this test, and DRIFT BEATS FAULT by
# design, so the audit's verdict would be unassertable. That is exactly how the
# BYO-only defect hid inside provider.t.
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
printf '%s' "$_clean" > "$T/clean.json"
printf '%s' "$_both"  > "$T/both.json"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_STATE=$T/state \
    CHARON_TRAITS_DIR=$T/state/traits UNISON_DIR=$T/uni \
    XDG_CONFIG_HOME=$T/xdg sh "$HERE/bin/charon" "$@"
}
REC=$T/state/audit/gd

# --- a clean remote: record written, exit 0 ---
AUDIT_JSON=$T/clean.json _c audit >/dev/null 2>&1 \
  || fail "audit of a clean remote reported a problem"
[ -f "$REC" ] || fail "audit wrote no record at $REC"
grep -q '^REMOTE=gd$' "$REC" || fail "the record does not name the remote"
grep -q '^AUDITED=[0-9]' "$REC" || fail "the record carries no timestamp"
grep -q '^DUPE=' "$REC" && fail "a clean remote recorded a DUPE line" || :

# --- a dirty remote: non-zero, and the paths are named ---
out=$(AUDIT_JSON=$T/both.json _c audit 2>&1); rc=$?
[ "$rc" = 0 ] && fail "audit of a DIRTY remote exited 0 ($out)" || :
grep -q '^DUPE=2 Docs/x.xlsx$' "$REC" \
  || fail "the dirty record does not name the duplicated path: $(cat "$REC")"
printf '%s\n' "$out" | grep -q 'rclone dedupe' \
  || fail "the report does not name the remedy; a verdict with no remedy sends
    the reader hunting ($out)"

# --- A FAILED LISTING MUST NOT REPLACE THE RECORD WITH A PARTIAL ONE ---
# Otherwise a transient rclone failure would quietly turn "2 duplicates" into
# "all clear", which is the worst direction for this particular check.
_before=$(md5sum "$REC" | cut -d' ' -f1)
AUDIT_FAIL=1 AUDIT_JSON=$T/clean.json _c audit >/dev/null 2>&1 \
  && fail "a FAILED remote listing reported success" || :
[ "$(md5sum "$REC" | cut -d' ' -f1)" = "$_before" ] \
  || fail "a failed listing overwrote the previous record; a transient error
    would read as 'all clear':
$(cat "$REC")"

# --- AN UNKNOWN SOURCE NAME MUST REFUSE NON-ZERO, not print an error and
# --- report success. charon-source's gate prints the refusal, and its exit was
# --- being SWALLOWED here: the provider lookup failed, the loop carried on, and
# --- do_audit returned 0. A refusal that exits 0 is what an integrator reads as
# --- all clear.
out=$(_c audit nosuchsource 2>&1); rc=$?
[ "$rc" = 0 ] \
  && fail "audit of an unknown source reported SUCCESS: $out" || :
printf '%s\n' "$out" | grep -q "no such source 'nosuchsource'" \
  || fail "audit of an unknown source did not refuse by name: $out"

# --- PROVIDER=none has no remote API, and that is not a failure ---
printf 'SOURCE=byo:Docs\n' > "$CFG/profiles.d/byo.conf"
AUDIT_JSON=$T/clean.json _c audit >/dev/null 2>&1 || :
[ -e "$T/state/audit/byo" ] \
  && fail "a PROVIDER=none source got an audit record; it has no remote
    API to audit" || :
rm -f "$CFG/profiles.d/byo.conf"

#### THE CHECK, which must read the record and never pay for a listing ####
# install first, so check has units/prfs to look at and the audit lines are the
# only thing under test.
AUDIT_JSON=$T/clean.json _c install >/dev/null 2>&1 || :

AUDIT_JSON=$T/clean.json _c audit >/dev/null 2>&1
# BASELINE GATE. The verdict assertions below are meaningless over a check that
# is already non-zero, and DRIFT BEATS FAULT, so any stray drift would mask the
# fault this test exists to prove.
_c check >/dev/null 2>&1 \
  || fail "BASELINE check is already non-zero on a clean audit, so the FAULT
    assertion below could not distinguish its own failure from the baseline's:
$(_c check 2>&1 | grep -E '\[FAIL\]|\[FAULT\]')"
out=$(_c check 2>&1)
printf '%s\n' "$out" | grep -q "\[OK\].*no duplicate names" \
  || fail "check did not report a clean audit ($out)"
printf '%s\n' "$out" | grep -qi 'ago ago' \
  && fail "check printed 'ago ago'; human_age already supplies it" || :

# a finding must be a FAULT (exit 2), because install cannot collapse a
# duplicate: that means choosing which object survives.
{ printf 'AUDITED=%s\nREMOTE=gd\n' "$(date +%s)"
  printf 'DUPE=2 Docs/x.xlsx\nNOCONTENT=Docs/x.xlsx\n'; } > "$REC"
_c check >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] || fail "a recorded duplicate gave check verdict $rc, wanted 2
  (FAULT): an apply cannot fix it, so calling it DRIFT would make an integrator
  loop forever"
out=$(_c check 2>&1)
printf '%s\n' "$out" | grep -q '\[FAULT\].*1 duplicated path' \
  || fail "the FAULT line did not COUNT the duplicates. The first record format
    used NOCONTENT= for both a path and a count, so the count read back a
    path ($out)"
printf '%s\n' "$out" | grep -q '1 contentless object' \
  || fail "the FAULT line did not count the contentless objects ($out)"

# never audited: a WARN, not a verdict. An absent measurement is not evidence
# of a problem, and an install cannot create one.
rm -f "$REC"
_c check >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] \
  || fail "a never-audited source made check exit $rc; absence of a measurement
    is not a finding, and nothing an apply does would produce one"
_c check 2>&1 | grep -q 'never been audited' \
  || fail "a never-audited source was not mentioned at all"

pass "remote audit: parses, records, refuses partials, and FAULTs via check"
