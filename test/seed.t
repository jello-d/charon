#!/bin/sh
# seed.t - seeding: the direction, the ordering, the lock, and degrading.
#
# THE GAP THIS CLOSES. Seeding was the largest wholly untested surface left in
# charon. It WRITES (it populates the cache), it shells out to `rclone copy`,
# and `charon install` kicks it in the background on every fresh install -- so
# it runs unattended, on a real remote, with nobody watching.
#
# The property that matters most is the DIRECTION. The whole justification for
# letting install fire a background seed is "it CANNOT write the remote, because
# the direction is remote -> cache". That is an argument about an argv, and
# nothing checked the argv. A transposition there would upload a half-empty
# cache over the authoritative copy -- the single worst thing this project can
# do, and the failure mode it has spent its whole history guarding against from
# the other direction.
. "$(dirname "$0")/lib.sh"
harness_init seed

export CHARON_LIBEXEC=$HERE/libexec
export CHARON_LIB_ONLY=1
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_TRAITS_DIR=$T/st
export UNISON_DIR=$T/uni
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/cache" "$T/st" \
         "$T/.cache" "$T/uni"
PATH="$T/bin:$PATH"

# rclone that RECORDS its argv and copies nothing. What it was ASKED to do is
# the entire question here.
cat > "$T/bin/rclone" <<EOF
#!/bin/sh
echo "\$*" >> "$T/rclone.log"
case "\$1" in
  listremotes) printf 'gd:\n' ;;
  about)       exit \${RCLONE_ABOUT_RC:-0} ;;
  copy)        exit \${RCLONE_COPY_RC:-0} ;;
esac
exit 0
EOF
chmod +x "$T/bin/rclone"
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/systemctl.log"
exit 0
EOF
chmod +x "$T/bin/systemctl"
for s in unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done

cat > "$CFG/sources.d/gd.conf" <<EOF
PROVIDER=rclone
REMOTE=gd
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
mkdir -p "$T/mnt/Media" "$T/mnt/Docs"
# Three profiles: two join the full seed in a DEFINED order, one does not join
# at all, and one carries a priority subtree.
printf 'SOURCE=gd:Media\nSEED_FULL_ORDER=20\nSEED_PRIORITY=Media/wallpaper\n' \
  > "$CFG/profiles.d/media.conf"
printf 'SOURCE=gd:Docs\nSEED_FULL_ORDER=10\n' > "$CFG/profiles.d/documents.conf"
printf 'SOURCE=gd:Scratch\n' > "$CFG/profiles.d/scratch.conf"

# shellcheck disable=SC1090
. "$CHARON_LIBEXEC/charon-sync"

_reset() { : > "$T/rclone.log"; : > "$T/systemctl.log"; }
_copies() { grep '^copy ' "$T/rclone.log" 2>/dev/null; }

#### THE DIRECTION: remote -> cache, never the reverse ####
_reset
seed_profile media Media/wallpaper || fail "a healthy seed reported failure"
_c=$(_copies); [ -n "$_c" ] || fail "seed_profile ran no rclone copy at all"
# argv must be `copy <remote>:<subtree> <cache>/<subtree>`, in that order.
printf '%s\n' "$_c" \
  | grep -q "^copy gd:Media/wallpaper $T/cache/Media/wallpaper" \
  || fail "seed argv is not remote->cache. THIS IS THE DATA-SAFETY PROPERTY
    that justifies install firing a background seed at all. Got: $_c"
# and belt-and-braces: the remote must never appear as the DESTINATION
printf '%s\n' "$_c" | awk '{print $3}' | grep -q '^gd:' \
  && fail "the REMOTE was passed as the copy DESTINATION -- a seed would
    overwrite the authoritative copy with the cache ($_c)" || :

# --- THE SEED MUST NOT PULL charon's OWN LITTER DOWN -------------------------
# rclone knows nothing about the prf's Tier 0 ignores, so a bare `rclone copy`
# pulled the remote's unison temps and probe scratch into the cache on every
# sweep and every fresh install -- straight past the patterns charon itself
# declares as never-content. Harmless while both ends ignore them, but it is
# asserted-vs-actual drift, and the moment an ignore is removed the litter is
# live data.
printf '%s\n' "$_c" | grep -q -- "--exclude $CRUMB_GLOB" \
  || fail "the seed does not exclude unison's transfer temps, so it copies
    charon's own litter into the cache: $_c"
printf '%s\n' "$_c" | grep -q -- "--exclude $PROBE_DIR_NAME/\*\*" \
  || fail "the seed does not exclude the probe scratch dir. It needs the '/**'
    form: rclone reads a bare '$PROBE_DIR_NAME' as a FILE pattern and silently
    excludes NOTHING, which is the spelling that looks right in a diff and does
    nothing in production (measured 2026-09-27): $_c"
# The patterns come from ONE place, so the seed cannot disagree with the prf
# about what is litter. Assert the LINKAGE, not two matching literals.
_seedx=$(never_content_excludes | tr '\n' ' ')
for _x in $_seedx; do
  case $_x in --exclude) continue ;; esac
  printf '%s\n' "$_c" | grep -qF -- "$_x" \
    || fail "never_content_excludes offers '$_x' but the seed did not pass it,
      so the shared list is not actually what reaches rclone: $_c"
done

# AND THE DIRECTION SURVIVES THE EXCLUDES. Building an argv list with `set --`
# replaces the FUNCTION's own positional parameters, so an earlier version read
# $2/$3 AFTER building the list and asked rclone to copy from `gd:--exclude`.
# This is the same assertion as above, re-stated because the excludes are what
# put it at risk.
printf '%s\n' "$_c" \
  | grep -q "^copy gd:Media/wallpaper $T/cache/Media/wallpaper " \
  || fail "the source and destination were corrupted by the exclude list: $_c"

#### an empty or missing subtree is a no-op, not a copy of everything ####
# `rclone copy gd: <cache>` with an empty subtree would seed the WHOLE remote
# into the cache root. Cheap to get wrong, expensive to notice.
_reset
seed_profile media "" || fail "an empty subtree should be a silent no-op"
[ -z "$(_copies)" ] || fail "an EMPTY subtree still ran a copy: $(_copies)"
_reset
seed_profile no-such-profile Media || :
[ -z "$(_copies)" ] || fail "an unknown profile still ran a copy: $(_copies)"

#### SEED_PRIORITY: only profiles that declare one, and only that subtree ####
_reset
seed_priority || fail "seed_priority reported failure on a healthy tree"
_c=$(_copies)
printf '%s\n' "$_c" | grep -q 'gd:Media/wallpaper' \
  || fail "the declared SEED_PRIORITY subtree was not seeded ($_c)"
[ "$(printf '%s\n' "$_c" | grep -c '^copy ')" = 1 ] \
  || fail "seed_priority seeded more than the one declared priority: $_c"

#### SEED_FULL_ORDER: ascending, and a profile without one does NOT join ####
_reset
_order=$(full_profiles | tr '\n' ' ')
[ "$_order" = "documents media " ] \
  || fail "full seed order wrong: expected 'documents media ' (10 then 20),
    got '$_order'"
printf '%s\n' "$_order" | grep -q scratch \
  && fail "a profile with NO SEED_FULL_ORDER joined the full seed anyway" || :

#### seed_full: bulk-seeds each joined profile's whole subtree, in order ####
_reset
seed_full >/dev/null 2>&1 || fail "seed_full reported failure on a healthy tree"
_c=$(_copies)
printf '%s\n' "$_c" | head -1 | grep -q 'gd:Docs' \
  || fail "seed_full did not honour SEED_FULL_ORDER (Docs=10 must be first):
$_c"
printf '%s\n' "$_c" | grep -q 'gd:Media' \
  || fail "seed_full skipped the second ordered profile: $_c"

# ...and it kicks the reconcile SEQUENTIALLY, never --no-block. All profiles
# share ONE sync lock, so firing them all at once guaranteed every profile after
# the first hit the lock and recorded a SKIPPED run -- a warning after every
# single install, which is a warning nobody reads.
grep -q 'no-block' "$T/systemctl.log" \
  && fail "seed_full kicked the syncs with --no-block; they contend on one lock
    and all but the first record a spurious SKIPPED run" || :
grep -q 'start charon-sync@' "$T/systemctl.log" \
  || fail "seed_full never kicked the reconcile at all"

#### the LOCK: a seed must stand down if a sync is running ####
# Seeding writes into the same cache a pass is reconciling.
_reset
( flock 9; sleep 3 ) 9>"$LOCKFILE" &
_holder=$!
sleep 1
out=$(seed_full 2>&1); rc=$?
wait "$_holder" 2>/dev/null || :
[ "$rc" = 0 ] || fail "a lock-held seed_full must stand down cleanly, got $rc"
[ -z "$(_copies)" ] \
  || fail "seed_full copied while a sync held the lock: $(_copies)"
printf '%s\n' "$out" | grep -qi 'lock' \
  || fail "the lock-held seed did not say why it did nothing ($out)"

#### a FAILED copy warns and reports, but does not abort the remaining work ####
_reset
RCLONE_COPY_RC=1 seed_full >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && fail "seed_full hid a failed copy behind exit 0" || :
[ "$(_copies | wc -l)" -ge 2 ] \
  || fail "a failed copy aborted the remaining profiles; seeding is resumable
    and must attempt each ($(_copies))"

#### PROVIDER=none cannot bulk-seed, and that is NOT a failure ####
# Seeding is an optimisation: the reconciler populates the cache anyway.
cat > "$CFG/sources.d/byo.conf" <<EOF
PROVIDER=none
MOUNT=$T/byo
CACHE_ROOT=$T/byocache
EOF
mkdir -p "$T/byo/Files" "$T/byocache"
printf 'SOURCE=byo:Files\nSEED_FULL_ORDER=5\n' > "$CFG/profiles.d/byo.conf"
_reset
seed_profile byo Files || fail "a PROVIDER=none seed was reported as a FAILURE"
[ -z "$(_copies)" ] || fail "a PROVIDER=none source was bulk-copied: $(_copies)"

# --- AND THOSE PATTERNS REALLY DO EXCLUDE, against REAL rclone ---------------
# The assertions above prove the flags are PASSED. They cannot prove the flags
# WORK, and rclone's filter rules are not unison's -- which is the whole reason
# this needed measuring rather than assuming. A pattern that looks right
# and excludes nothing is the exact failure mode here, so the semantics get a
# behavioural test of their own.
#
# Uses the real tool on two local directories, which needs no remote and no
# network. Skipped rather than faked when rclone is absent: a stub cannot tell
# us anything about rclone's matching.
#
# THE REAL BINARY IS RESOLVED BY PATH SEARCH, NOT `command -v`. This file puts
# its own rclone STUB first on PATH, so `command -v rclone` finds the STUB, and
# the first version of this test "measured" rclone's filter semantics against a
# script that copies nothing -- it duly reported that the excludes had eaten all
# the content. Same family as the rule that removing a stub does not simulate an
# absent tool, pointed the other way: here the stub is the thing to avoid.
_realrclone=
for _d in /usr/local/bin /usr/bin /bin /snap/bin "$HOME/.local/bin"; do
  [ -x "$_d/rclone" ] && { _realrclone=$_d/rclone; break; }
done
case $_realrclone in
  "$T"/*) fail "resolved the test's own rclone STUB as the real binary" ;;
esac
if [ -n "$_realrclone" ]; then
  RB=$T/realrclone
  mkdir -p "$RB/src/deep/deeper" "$RB/dst"
  # litter at the root, one level down, and two
  printf 'x' > "$RB/src/.unison.root.psp.aaa.unison.tmp"
  printf 'x' > "$RB/src/deep/.unison.mid file.psp.bbb.unison.tmp"
  printf 'x' > "$RB/src/deep/deeper/.unison.deep.psp.ccc.unison.tmp"
  mkdir -p "$RB/src/$PROBE_DIR_NAME" "$RB/src/deep/$PROBE_DIR_NAME"
  printf 'x' > "$RB/src/$PROBE_DIR_NAME/p.txt"
  printf 'x' > "$RB/src/deep/$PROBE_DIR_NAME/p.txt"
  # real content, including names a sloppy pattern would eat
  printf 'x' > "$RB/src/real file.psp"
  printf 'x' > "$RB/src/deep/real deep.psp"
  printf 'x' > "$RB/src/unison-notes.txt"
  printf 'x' > "$RB/src/$PROBE_DIR_NAME-not-a-dir.txt"

  set --
  while IFS= read -r _x; do set -- "$@" "$_x"; done <<EOF
$(never_content_excludes)
EOF
  "$_realrclone" copy "$RB/src" "$RB/dst" "$@" >/dev/null 2>&1 \
    || fail "real rclone copy failed in the behavioural exclude test"
  # Assert the HARNESS is honest before asserting anything about rclone: an
  # empty destination would make every exclude assertion below pass for free.
  [ -n "$(find "$RB/dst" -mindepth 1 2>/dev/null)" ] \
    || fail "the rclone copy produced an EMPTY destination, so the exclude
    assertions below would pass for the wrong reason (is $_realrclone real?)"
  _got=$(find "$RB/dst" -mindepth 1 | sed "s|^$RB/dst/||" | sort | tr '\n' ' ')

  # NOTHING charon calls litter may have landed, at ANY depth.
  case $_got in
    *unison.tmp*) fail "a unison transfer temp was copied into the cache
      despite the exclude: [$_got]" ;;
  esac
  case $_got in
    *"$PROBE_DIR_NAME/"*) fail "the probe scratch was copied into the cache
      despite the exclude. rclone reads a bare directory name as a FILE pattern
      and matches nothing, which is why the '/**' form is used: [$_got]" ;;
  esac

  # ...and everything that IS content did land. An exclude that also ate real
  # files would be far worse than the litter it removed.
  for _want in 'real file.psp' 'deep/real deep.psp' 'unison-notes.txt' \
               "$PROBE_DIR_NAME-not-a-dir.txt"; do
    case " $_got " in
      *" $_want "*) : ;;
      *) fail "the excludes ate real content: '$_want' is missing from
         [$_got]" ;;
    esac
  done
else
  echo "  (note: no real rclone; exclude SEMANTICS not behaviourally tested)"
fi

pass "seeding: remote->cache only, ordered, lock-aware, and degrades"
