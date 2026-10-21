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
mkdir -p "$T/bin" "$T/log" "$CFG/profiles.d" "$CFG/sources.d" "$T/state" \
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
# The same, with the MOUNT'S OWN VIEW supplied: a --drive-skip-gdocs listing.
# A -1 object the mount OMITS is export-only (a Google doc) and is no finding;
# one the mount PRESENTS is unexplained. Measuring that is the whole fix.
_parse_skip() { printf '%s' "$2" > "$T/skip.json"
                printf '%s' "$1" | audit_report "$3" "$T/skip.json"; }

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

#### THE EXPORT-ONLY CLASSIFICATION, which is the 2026-10-20 fix ####
# A `Size: -1` means "no STORED size", not "no content". Measured on the live
# remote: four such objects were FULLY READABLE (26249, 182337 and 321276 bytes,
# each with a PK zip header) because they are native Google docs, which are
# export-only. They had faulted the whole fleet for four days.
# The question that decides it is whether the MOUNT presents the object, and
# `--drive-skip-gdocs` is the authority because it is the flag the mount runs
# with.
_gdoc='[{"Path":"sheet.xlsx","Name":"sheet.xlsx","Size":-1}]'
# the mount's view OMITS it -> export-only, not a finding
out=$(_parse_skip "$_gdoc" '[]' Docs)
printf '%s\n' "$out" | grep -qx 'SKIPPED=Docs/sheet.xlsx' \
  || fail "a -1 object the MOUNT OMITS was not classified export-only. It
reaches no cache and conflicts with nothing, so calling it contentless is the
false fault this fixes: $out"
printf '%s\n' "$out" | grep -q '^NOCONTENT=' \
  && fail "an export-only object was still reported as contentless: $out" || :

# the mount's view PRESENTS it -> charon cannot account for it, so say so
out=$(_parse_skip "$_gdoc" "$_gdoc" Docs)
printf '%s\n' "$out" | grep -qx 'NOCONTENT=Docs/sheet.xlsx' \
  || fail "a -1 object the mount DOES present was waved through. An
export-only object would have been omitted and a real one would have a size,
so this one is unexplained and must be reported: $out"
printf '%s\n' "$out" | grep -q '^SKIPPED=' \
  && fail "a presented object was called export-only: $out" || :

# AN ABSENT MEASUREMENT IS NOT AN ALL-CLEAR. With no skip listing at all, a -1
# must stay unexplained rather than be assumed export-only, or a failed second
# listing would silently clear every finding.
out=$(_parse "$_neg" Docs)
printf '%s\n' "$out" | grep -qx 'NOCONTENT=Docs/a.txt' \
  || fail "with the mount's view UNMEASURED, a -1 was not reported: $out"

# A GDOC BESIDE A REAL FILE IS TWO OBJECTS ON THE REMOTE AND ONE TO THE MOUNT,
# so the mount stays deterministic and nothing conflicts. Counting the RAW
# listing reported exactly this benign pair as the 2026-10-04 hazard, which is
# the same error as reading Size alone, one level up. Measured on the live
# remote: two such pairs, the mount seeing one object each.
# IDs are what make it per-OBJECT: the path IS presented (via the real
# sibling), so a path-level test calls the gdoc unexplained.
_pair='[{"Path":"x.xlsx","Name":"x.xlsx","Size":28226,"ID":"real1"},
        {"Path":"x.xlsx","Name":"x.xlsx","Size":-1,"ID":"gdoc1"}]'
_pairmount='[{"Path":"x.xlsx","Name":"x.xlsx","Size":28226,"ID":"real1"}]'
out=$(_parse_skip "$_pair" "$_pairmount" Docs)
[ -z "$out" ] \
  || fail "a gdoc beside a real file was reported as a finding. The mount sees
ONE object there and presents the real one, so it is deterministic and nothing
conflicts: $out"

# THE REAL 2026-10-04 HAZARD STILL IS ONE: the MOUNT itself sees two objects at
# one path, so the content it presents flips between passes.
_mountdup='[{"Path":"x.xlsx","Name":"x.xlsx","Size":28226,"ID":"a"},
            {"Path":"x.xlsx","Name":"x.xlsx","Size":28226,"ID":"b"}]'
out=$(_parse_skip "$_mountdup" "$_mountdup" Docs)
printf '%s\n' "$out" | grep -qx 'DUPE=2 Docs/x.xlsx' \
  || fail "the 2026-10-04 hazard stopped being reported. The MOUNT sees two
objects at this path, which is what makes its content non-deterministic: $out"

# ...and a -1 object the MOUNT WILL USE is still unexplained, because an
# export-only object would have been omitted and a real one would have a size.
_mountneg='[{"Path":"x.xlsx","Name":"x.xlsx","Size":-1,"ID":"odd"}]'
out=$(_parse_skip "$_mountneg" "$_mountneg" Docs)
printf '%s\n' "$out" | grep -qx 'NOCONTENT=Docs/x.xlsx' \
  || fail "a sizeless object the mount WILL present was waved through: $out"
unset CHARON_LIB_ONLY

#### THE RECORD + THE VERB, with a stubbed rclone ####
cat > "$T/bin/rclone" <<STUB
#!/bin/sh
# RECORDS ITS ARGV, and ANSWERS DIFFERENTLY with --drive-skip-gdocs, because
# that flag is the whole mechanism: it is the mount's own view, and the audit
# classifies a -1 object by whether the mount presents it. A stub that ignored
# the flag made do_audit's wiring unassertable, and a mutation dropping the flag
# SURVIVED until this stub could tell the two listings apart.
echo "rclone \$*" >> "$T/log/rclone"
case "\$1" in
  lsjson)
    [ -n "\${AUDIT_FAIL:-}" ] && exit 7
    case " \$* " in
      *" --drive-skip-gdocs "*) cat "\${AUDIT_SKIP_JSON:-\${AUDIT_JSON:?}}" ;;
      *)                        cat "\${AUDIT_JSON:?}" ;;
    esac ;;
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

# --- THE EXPORT-ONLY PATH, END TO END THROUGH do_audit ---
# The parser cases above are given the mount's view directly. This proves
# do_audit actually ASKS for it: the stub answers differently when it sees
# --drive-skip-gdocs, so a mutation dropping the flag now changes the verdict.
# It SURVIVED before this case existed.
printf '[{"Path":"sheet.xlsx","Name":"sheet.xlsx","Size":-1}]' > "$T/gdoc.json"
printf '[]' > "$T/none.json"
: > "$T/log/rclone"
out=$(AUDIT_JSON=$T/gdoc.json AUDIT_SKIP_JSON=$T/none.json _c audit 2>&1); rc=$?
[ "$rc" = 0 ] \
  || fail "audit of a remote whose only oddity is an EXPORT-ONLY object exited
    $rc. The mount omits it, so it reaches no cache and conflicts with
    nothing ($out)"
grep -q '^SKIPPED=Docs/sheet.xlsx$' "$REC" \
  || fail "the export-only object was not recorded as skipped:
$(cat "$REC")"
grep -q '^NOCONTENT=' "$REC" \
  && fail "an export-only object was recorded as contentless, which is the
    false fault this release fixes: $(cat "$REC")" || :
grep -q -- '--drive-skip-gdocs' "$T/log/rclone" \
  || fail "do_audit never asked for the MOUNT'S view. Without that listing the
    classification is an inference from Size alone, which is what was wrong:
$(cat "$T/log/rclone")"
printf '%s\n' "$out" | grep -q 'dedupe' \
  && fail "an export-only finding offered the dedupe remedy ($out)" || :

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
{ printf 'SCHEMA=2\nAUDITED=%s\nREMOTE=gd\n' "$(date +%s)"
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
printf '%s\n' "$out" | grep -q "no stored size" \
  || fail "the FAULT line did not report the no-stored-size objects ($out)"
# AND THE TWO FINDINGS ARE SEPARATE LINES NOW. One line used to carry both
# counts and then offer only the dedupe remedy, so a remote with 0 duplicates
# was told to collapse duplicates under an explanation that did not apply.
[ "$(printf '%s\n' "$out" | grep -c '\[FAULT\]')" -ge 2 ] \
  || fail "the duplicate and the unexplained object were reported as ONE
    finding; they have different causes and different remedies ($out)"

# A REMOTE WITH **ZERO** DUPLICATES MUST NOT BE TOLD TO RUN dedupe. This is the
# shape that faulted the live fleet for four days: 0 duplicated paths, and a
# dedupe remedy in the same sentence that reported the zero.
{ printf 'SCHEMA=2\nAUDITED=%s\nREMOTE=gd\n' "$(date +%s)"
  printf 'NOCONTENT=Docs/x.xlsx\n'; } > "$REC"
out=$(_c check 2>&1)
printf '%s\n' "$out" | grep -q 'dedupe' \
  && fail "a remote with NO duplicates was told to run 'rclone dedupe', which
    has nothing to collapse: $out" || :
printf '%s\n' "$out" | grep -qi 'duplicate name makes the mount' \
  && fail "the duplicate-name explanation was given for a remote with no
    duplicate names: $out" || :

# AN EXPORT-ONLY OBJECT IS NOT A FINDING AT ALL, and faulting on it is the bug.
{ printf 'SCHEMA=2\nAUDITED=%s\nREMOTE=gd\n' "$(date +%s)"
  printf 'SKIPPED=Docs/sheet.xlsx\nSKIPPED=Docs/doc.docx\n'; } > "$REC"
_c check >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] \
  || fail "export-only objects gave check verdict $rc, wanted 0. The mount omits
    them, so they reach no cache and conflict with nothing; faulting on them
    reported 'needs attention' forever on a healthy fleet"
out=$(_c check 2>&1)
printf '%s\n' "$out" | grep -q '\[OK\].*2 export-only' \
  || fail "the OK line does not COUNT them. A file that will never appear in
    the cache is worth saying, even when it is not a fault ($out)"

# AN EXPORT-ONLY PATH WITH A REAL FILE STILL IN THE CACHE IS A WEDGE, and this
# is the rule that would have caught the live damage on 2026-10-16 instead of
# the false fault. Measured end to end: the mount cannot present the object, so
# every pass tries to CREATE the cache copy and collides with the invisible
# Google doc. manifestor burned 87 consecutive passes on one directory.
# UNWEDGE CANNOT HELP (a directory creation leaves no temp), so naming it is
# the only useful thing charon can do.
{ printf 'SCHEMA=2\nAUDITED=%s\nREMOTE=gd\n' "$(date +%s)"
  printf 'SKIPPED=Docs/sheet.xlsx\n'; } > "$REC"
mkdir -p "$T/cache/Docs"
printf 'stale pre-conversion copy\n' > "$T/cache/Docs/sheet.xlsx"
_c check >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] \
  || fail "an export-only path with a STALE CACHE COPY gave verdict $rc, wanted
    2. That state wedges the profile on every pass and no apply can clear it"
out=$(_c check 2>&1)
printf '%s\n' "$out" | grep -q '\[FAULT\].*EXPORT-ONLY' \
  || fail "the wedge was not reported as a fault ($out)"
printf '%s\n' "$out" | grep -q 'stale cache:.*Docs/sheet.xlsx' \
  || fail "the fault does not NAME the stale cache file, which is the one thing
    a human needs in order to act ($out)"
printf '%s\n' "$out" | grep -qi 'Drive UI' \
  || fail "the fault names only one of the two remedies; only the user can
    choose between dropping the cache copy and converting the file back ($out)"
# AND THE OK LINE MUST NOT PRINT ALONGSIDE IT. "remote had no duplicate names"
# is true and, printed next to a FAULT about the same source, reads as two
# verdicts for one thing. Found by mutation.
printf '%s\n' "$out" | grep -q "\[OK\].*source 'gd': remote had no" \
  && fail "an [OK] line for the same source printed alongside the [FAULT],
    which reads as two verdicts for one source ($out)" || :

# ...and with the cache copy GONE it is no finding at all, because an
# export-only object the cache does not mirror simply never syncs.
rm -f "$T/cache/Docs/sheet.xlsx"
_c check >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] \
  || fail "an export-only path with NO cache copy gave verdict $rc, wanted 0.
    Nothing is wedged: the file just never reaches the cache"
_c check 2>&1 | grep -q 'EXPORT-ONLY' \
  && fail "the wedge fault fired with no stale cache copy present" || :

# A PRE-SCHEMA RECORD CANNOT BE JUDGED. It was written before the export-only
# measurement existed, so it filed every Google doc under NOCONTENT; deriving a
# verdict from it reproduces the false FAULT for as long as it is stale.
{ printf 'AUDITED=%s\nREMOTE=gd\n' "$(date +%s)"
  printf 'NOCONTENT=Docs/sheet.xlsx\n'; } > "$REC"
_c check >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] \
  || fail "a PRE-SCHEMA record was judged, giving verdict $rc. Its NOCONTENT
    lines may be Google docs, so it must ask for a re-audit, not fault"
_c check 2>&1 | grep -q 'predates the export-only measurement' \
  || fail "a pre-schema record was not reported as unjudgeable"

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
