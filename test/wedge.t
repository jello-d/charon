#!/bin/sh
# wedge.t - WHY a path is wedged, and whether charon says so correctly.
#
# THE GAP THIS CLOSES, measured on manifestor 2026-11-05. The unwedge's trigger
# carried a hidden DIAGNOSIS: a streak means "this fault is not healing", and
# the code read it as "a stale temp is why". On a wedge whose real cause was a
# forgotten archive entry it dropped two temps (which the next pass re-stranded
# every time), announced that it had acted, and let the streak run from 3 to 8
# while the fault message sent the reader to ~/.unison/unison.log, where that
# cause does not appear.
#
# So the classifier is the thing under test here, and TWO properties matter
# more than the rest:
#
#   1. THE PRECEDENCE. FORGOTTEN_ARCHIVE must outrank STALE_TEMP, because the
#      live wedge had BOTH facts true at once and ranking the temp first is
#      exactly what produced a confident wrong answer for eight passes.
#   2. THE EXACT WORD. The remedy table DISPATCHES on which word comes back, so
#      a detector that returns the wrong one still "fires" and would pass any
#      assertion that only asks whether it answered. That is the `prove_word`
#      lesson from the shared conventions check, and it applies here for the
#      same reason: a vocabulary needs its words proven, not its non-emptiness.
. "$(dirname "$0")/harness_lib"
harness_init wedge

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

# ----------------------------------------------------------------- part 1 ----
# THE PURE CLASSIFIER. Every answer is reachable from a one-line call with no
# fixture on disk, which is the whole point of taking the facts as WORDS, and
# it is why this section can enumerate the dispatch exhaustively.
_cls() {   # <want> <four facts...>
  _w=$1; shift
  _g=$(wedge_class "$@")
  [ "$_g" = "$_w" ] || fail "wedge_class $*
  answered [$_g], wanted [$_w]. The remedy table dispatches on this word, so a
  wrong one prescribes a wrong fix with full confidence."
}

# One row per class, each reached on its own merits.
_cls SCAN_ERROR        notemp scan      unknown   unknown
_cls DUPE_OBJECTS      notemp propagate differ    dupe
_cls EXPORT_ONLY       notemp propagate differ    exportonly
_cls FORGOTTEN_DIR     notemp propagate dir       plain
_cls FORGOTTEN_ARCHIVE notemp propagate identical plain
_cls STALE_TEMP        temp   propagate differ    plain
_cls UNKNOWN           notemp propagate differ    plain

# THE PRECEDENCE, stated as the live case that forced it: a temp AND identical
# content on both replicas, which is what manifestor had. Ranking the temp
# first here is the bug, so this row is the regression.
_cls FORGOTTEN_ARCHIVE temp propagate identical plain
_cls FORGOTTEN_ARCHIVE temp propagate identical unknown

# A scan failure outranks every other fact, because it happened in a different
# PHASE: nothing was transferred, so no temp and no remote shape can explain it.
_cls SCAN_ERROR temp scan identical dupe
_cls SCAN_ERROR temp scan dir       exportonly

# Duplicate objects outrank the local reading, because they are what makes the
# mount non-deterministic in the first place: any other remedy would be applied
# to a moving target.
_cls DUPE_OBJECTS temp propagate identical dupe
_cls DUPE_OBJECTS temp propagate dir       dupe
# ...and export-only outranks the local reading for the same reason.
_cls EXPORT_ONLY  temp propagate identical exportonly

# An UNKNOWN remote verdict must not invent a remote finding, which is the
# difference between "the audit says this path is clean" and "there is no
# audit". Both fall through to the local reading.
_cls STALE_TEMP temp   propagate differ unknown
_cls UNKNOWN    notemp propagate differ unknown

# ----------------------------------------------------------------- part 2 ----
# EVERY CLASS HAS ITS OWN REMEDY. A class that silently fell through to the
# default would still print a sentence, so "non-empty" proves nothing; the
# sentences have to be DISTINCT, and the fallback's wording must appear only
# for a genuinely unknown class.
_dflt=$(wedge_remedy UNKNOWN docs 'p')
[ -n "$_dflt" ] || fail "the UNKNOWN remedy is empty"
_seen=$T/remedies; : > "$_seen"
for _c in SCAN_ERROR DUPE_OBJECTS EXPORT_ONLY FORGOTTEN_DIR \
          FORGOTTEN_ARCHIVE STALE_TEMP; do
  _r=$(wedge_remedy "$_c" docs 'some file.txt')
  [ -n "$_r" ] || fail "class $_c has no remedy text"
  [ "$_r" != "$_dflt" ] \
    || fail "class $_c fell through to the UNKNOWN remedy, so it is named in
  the classifier and unhandled in the table, which prescribes the wrong fix"
  printf '%s\n' "$_r" >> "$_seen"
done
[ "$(sort -u "$_seen" | wc -l)" = 6 ] \
  || fail "two classes share one remedy sentence; they prescribe different
  actions, so a shared sentence means one of them is wrong"

# The two remedies a human most needs must carry the ACTUAL command, not a
# gesture at one. These are the sentences that would have saved the hour.
_r=$(wedge_remedy FORGOTTEN_ARCHIVE docs 'some file.txt')
for _n in 'plan docs' '-path' 'unison charon-docs' "'some file.txt'"; do
  printf '%s' "$_r" | grep -qF -- "$_n" \
    || fail "the FORGOTTEN_ARCHIVE remedy does not name [$_n]:
  $_r"
done
printf '%s' "$_r" | grep -qF -- 'timers stopped' \
  || fail "the FORGOTTEN_ARCHIVE remedy omits 'timers stopped'; a hand-run
  unison bypasses charon's sync lock, which is the one way following this
  advice could hurt"
_r=$(wedge_remedy DUPE_OBJECTS docs 'p')
printf '%s' "$_r" | grep -qF -- 'rclone dedupe' \
  || fail "the DUPE_OBJECTS remedy does not name rclone dedupe: $_r"
_r=$(wedge_remedy SCAN_ERROR docs 'p')
printf '%s' "$_r" | grep -qiE 'fifo|socket|permission' \
  || fail "the SCAN_ERROR remedy does not say what to look at: $_r"

# ----------------------------------------------------------------- part 3 ----
# THE SCAN-WORDING PARSE, form 2 only. Reuses the sample shape that caught a
# surviving mutation before: a file genuinely NAMED `error  report.txt` is a
# legal name, so the row must be anchored on the COLUMN and not on the word, or
# an ordinary synced row yields a phantom failing path.
# tabs-are-data: a byte-level unison transcript, reproduced exactly.
printf 'Failed [propagated.txt]: Destination updated during synchronization\n' \
  > "$T/out"
printf '         error            unreadable dir/file.txt  \n' >> "$T/out"
printf '         error            name with spaces.bin  \n' >> "$T/out"
printf '[BGN] Copying error  report.txt from /a to /b\n' >> "$T/out"
_g=$(parse_unison_scan_failures "$T/out")
_w='name with spaces.bin
unreadable dir/file.txt'
[ "$_g" = "$_w" ] || fail "parse_unison_scan_failures returned
[$_g]
  wanted
[$_w]"
# It must NOT return the propagation failure: that is the whole distinction.
printf '%s\n' "$_g" | grep -qxF 'propagated.txt' \
  && fail "the scan parse returned a PROPAGATION failure, so the two wordings
  are not being told apart and the SCAN_ERROR class is unreachable" || :
# And the merged contract every other caller reads is UNCHANGED, which is the
# property that makes this a second reader rather than an edit.
_g=$(parse_unison_failures "$T/out")
for _n in 'propagated.txt' 'unreadable dir/file.txt' 'name with spaces.bin'; do
  printf '%s\n' "$_g" | grep -qxF -- "$_n" \
    || fail "parse_unison_failures no longer returns [$_n]; the merged list is
  the contract for everything that treats a failing path as a failing path"
done

# ----------------------------------------------------------------- part 4 ----
# THE RECORD CARRIES THE WORDING, because the capture is deleted before
# anything classifies the wedge.
record_failures docs 2 "$T/out"
_g=$(scan_failed_paths docs)
[ "$_g" = "$_w" ] || fail "the record did not carry the scan paths: [$_g]"
failed_paths docs | grep -qxF 'propagated.txt' \
  || fail "recording the wording lost the ordinary failing paths"
# A RECORD FROM AN OLDER VERSION has no such key, and must read as empty rather
# than as "nothing could be read": the classifier then says unknown instead of
# guessing. Driven by writing the old format, not by deleting a line, so this
# is the real upgrade path.
{ printf 'LAST=1\nRC=2\n'; printf 'FAILED=1 1 propagated.txt\n'; } \
  > "$(failed_file docs)"
[ -z "$(scan_failed_paths docs)" ] \
  || fail "a pre-SCANFAIL record answered the wording question anyway"
[ "$(failed_paths docs)" = 'propagated.txt' ] \
  || fail "a pre-SCANFAIL record lost its failing paths"

# ----------------------------------------------------------------- part 5 ----
# audit_path_class: THE SUBTREE HAS TO BE JOINED BACK ON. unison's paths are
# relative to the PROFILE's roots (which already include the subtree) and the
# audit records paths relative to the SOURCE, so comparing them raw matches
# nothing and reads as "the remote is fine" rather than as a bug. This project
# has already paid for that exact confusion once.
mkdir -p "$T/state/audit"
cat > "$T/state/audit/s" <<'EOF'
SCHEMA=1
AUDITED=1700000000
DUPE=D/two objects.xlsx
SKIPPED=D/converted.docx
EOF
_apc() {   # <want> <path>
  _g=$(audit_path_class docs "$2")
  [ "$_g" = "$1" ] || fail "audit_path_class '$2' answered [$_g], wanted [$1]"
}
_apc dupe       'two objects.xlsx'
_apc exportonly 'converted.docx'
_apc plain      'ordinary.txt'
# The raw record path must NOT match, or the join is not happening and the
# right answer above was luck.
_apc plain 'D/two objects.xlsx'

# A PRE-SCHEMA RECORD CANNOT BE JUDGED. It filed every Google doc under
# NOCONTENT, so trusting its words reproduces the false fault that cost this
# fleet five days; check_audit refuses to judge one and so must this.
cat > "$T/state/audit/s" <<'EOF'
AUDITED=1700000000
DUPE=D/two objects.xlsx
EOF
_apc unknown 'two objects.xlsx'
# NO RECORD AT ALL is unknown, not clean: an absent measurement is not evidence.
rm -f "$T/state/audit/s"
_apc unknown 'two objects.xlsx'

# ----------------------------------------------------------------- part 6 ----
# wedge_facts against a real fixture, which is the impure half. One case per
# fact, because a gatherer that always answers the same thing would satisfy any
# single-case test.
_facts() {   # <want> <path>
  _g=$(wedge_facts docs "$2")
  [ "$_g" = "$1" ] || fail "wedge_facts '$2' answered [$_g], wanted [$1]"
}
# IDENTICAL: same bytes, same mtime, which is exactly the comparison unison's
# own fastcheck makes. The mtime has to be set explicitly, because two files
# written in the same second already match and would pass for the wrong reason.
printf 'same\n' > "$T/src/D/both.txt"
printf 'same\n' > "$T/cache/D/both.txt"
touch -d '2026-01-01 00:00:00' "$T/src/D/both.txt" "$T/cache/D/both.txt"
_facts 'notemp propagate identical unknown' 'both.txt'

# DIFFER, by mtime alone at the same size: the case a size-only test would call
# identical, so it pins which comparison is being made.
printf 'same\n' > "$T/src/D/mtime.txt"
printf 'same\n' > "$T/cache/D/mtime.txt"
touch -d '2026-01-01 00:00:00' "$T/src/D/mtime.txt"
touch -d '2026-02-02 00:00:00' "$T/cache/D/mtime.txt"
_facts 'notemp propagate differ unknown' 'mtime.txt'

# DIFFER, one side only: the ordinary pending create.
printf 'only\n' > "$T/src/D/oneside.txt"
_facts 'notemp propagate differ unknown' 'oneside.txt'

# DIR, which gets its own class because the remedy branches on the cache copy.
mkdir -p "$T/src/D/adir" "$T/cache/D/adir"
_facts 'notemp propagate dir unknown' 'adir'

# TEMP, named the way unison names one, so the fixture matches CRUMB_GLOB.
printf 'partial' \
  > "$T/src/D/.unison.oneside.txt.aabbccddeeff00112233445566778899.unison.tmp"
_facts 'temp propagate differ unknown' 'oneside.txt'

# THE WORDING reaches the facts through the RECORD, not through a capture.
printf 'LAST=1\nRC=1\nFAILED=1 1 oneside.txt\nSCANFAIL=oneside.txt\n' \
  > "$(failed_file docs)"
_facts 'temp scan differ unknown' 'oneside.txt'
: > "$(failed_file docs)"

# ----------------------------------------------------------------- part 7 ----
# THE TWO CONSUMERS AGREE, which is why the verdict is one shared function
# rather than two call sites computing it: profile_outcome exists for the same
# reason, after two copies of "EX_SKIP is not a success" could have disagreed
# about one run.
_v=$(wedge_verdict docs 'both.txt')
case $_v in
  'FORGOTTEN_ARCHIVE: '*) ;;
  *) fail "wedge_verdict did not lead with the class: [$_v]" ;;
esac
printf '%s' "$_v" | grep -qF -- '-path' \
  || fail "wedge_verdict carries the class but not the remedy: $_v"

# THE FAULT MESSAGE, which is the half a human actually reads: it is the
# journal line AND the notify flag. Driven through the real function rather
# than inspected, because the assembly sat inline and untestable until it was
# extracted, and "the wiring is only two lines" is how two untested lines ship.
printf 'LAST=1\nRC=2\nFAILED=4 1 both.txt\n' > "$(failed_file docs)"
_m=$(fault_message docs charon-docs 2)
printf '%s' "$_m" | grep -qF 'Unison charon-docs failed (exit 2)' \
  || fail "the fault message lost its opening: $_m"
printf '%s' "$_m" | grep -qF 'e.g. both.txt' \
  || fail "the fault message no longer names a path; that regression is the
  2026-09-24 one, where a human grepped the journal for paths unison had
  already printed: $_m"
printf '%s' "$_m" | grep -qF 'FORGOTTEN_ARCHIVE' \
  || fail "the fault message does not name the wedge class, so the flag still
  says only that something failed: $_m"
printf '%s' "$_m" | grep -qF -- '-path' \
  || fail "the fault message names the class but not the remedy: $_m"
# AND IT MUST NOT STILL SEND THE READER TO THE LOG when it has a real verdict:
# that sentence is what pointed at the wrong place on 2026-11-05.
printf '%s' "$_m" | grep -qF 'unison.log' \
  && fail "the fault message carries a verdict AND the old 'check the log'
  sentence; the second one is what sent the reader to the wrong place: $_m" || :

# WITH NOTHING ATTRIBUTABLE, the old sentence is correct and must survive: the
# log really is the next place to look when charon cannot name a path.
printf 'LAST=1\nRC=2\n' > "$(failed_file docs)"
_m=$(fault_message docs charon-docs 2)
printf '%s' "$_m" | grep -qF 'unison.log' \
  || fail "with no attributable path the fault message must still point at the
  log, which is genuinely the next place to look: $_m"
printf '%s' "$_m" | grep -qF 'FORGOTTEN' \
  && fail "the fault message classified a wedge with no path to classify" || :

pass "7 wedge classes, the precedence that was the bug, and both consumers"
