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

pass "seeding: remote->cache only, ordered, lock-aware, and degrades"
