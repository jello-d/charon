#!/bin/sh
# provider.t - a BYO source (PROVIDER=none) must actually WORK, with no rclone
# anywhere in the picture.
#
# This is the test the docs were writing cheques for. The config vocabulary
# accepted PROVIDER=none and the example file promised such a source "still
# reconciles, still gates, still refuses a source gone empty" -- but the gate
# ran `rclone about <global remote>:` unconditionally, so a source with no
# rclone remote came back offline on EVERY pass and skipped forever. The seam
# existed; it did not work. A declaration nothing exercises is a promise.
. "$(dirname "$0")/lib.sh"
harness_init provider

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
CFG=$XDG_CONFIG_HOME/charon
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" \
         "$T/nas/Docs" "$T/nascache/Docs"
echo content > "$T/nas/Docs/a.txt"

# NO rclone on PATH AT ALL. If anything in the sync half still reaches for it,
# this test fails, which is the point.
for s in systemctl unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

cat > "$CFG/sources.d/nas.conf" <<EOF
PROVIDER=none
MOUNT=$T/nas
CACHE_ROOT=$T/nascache
EOF
printf 'SOURCE=nas:Docs\n' > "$CFG/profiles.d/docs.conf"

_c() { PATH="$T/bin:/usr/bin:/bin" sh "$HERE/bin/charon" "$@"; }

# --- the provider answers for a tree it does not own ---
_c source status nas >/dev/null 2>&1 \
  || fail "PROVIDER=none source reported DOWN when its tree is present"
out=$(_c source health nas 2>&1); rc=$?
[ "$rc" = 0 ] || fail "PROVIDER=none source reported unhealthy (rc=$rc)"
printf '%s\n' "$out" | grep -qx online || fail "health did not say online"

# a plain directory must NOT be required to be a mountpoint: only a source
# charon mounted itself carries that requirement.
rm -f "$T/bin/mountpoint"
_c source status nas >/dev/null 2>&1 \
  || fail "a plain directory was rejected for not being a mountpoint"

# --- install, and then a REAL pass, with no rclone anywhere ---
_c install >/dev/null 2>&1 || fail "install failed for a PROVIDER=none source"
[ -f "$T/.unison/charon-docs.prf" ] || fail "no prf generated"
grep -q "^root = $T/nas/Docs\$" "$T/.unison/charon-docs.prf" \
  || fail "prf did not use the BYO source's MOUNT"

out=$(_c sync docs 2>&1); rc=$?
[ "$rc" = 75 ] && fail "BYO source SKIPPED: the gate still wants rclone
    ($out)"
[ "$rc" = 0 ] || fail "BYO sync failed rc=$rc ($out)"

# --- traits: a local tree is POSIX, so none of the cloud prefs apply ---
TF=$T/.local/state/charon/traits/nas
grep -q '^PERMS=posix$' "$TF" || fail "BYO source traits not measured as POSIX"
grep -q '^perms = 0$' "$T/.unison/charon-docs.prf" \
  && fail "a POSIX source was told to discard permissions" || :

# --- seeding degrades instead of failing: it is an optimisation ---
# PROVIDER=none cannot bulk-copy, and that must not be an error.
_c seed >/dev/null 2>&1 || fail "seed errored on a provider that cannot seed"
_c seed --priority >/dev/null 2>&1 || fail "priority seed errored"

# --- the dead-source guard still applies to a BYO source ---
rm -f "$T/nas/Docs/a.txt"                 # source subtree now empty...
echo keep > "$T/nascache/Docs/keep.txt"   # ...while the cache holds data
out=$(_c sync docs 2>&1); rc=$?
[ "$rc" = 0 ] && fail "empty BYO source was ALLOWED to propagate deletions" || :
printf '%s\n' "$out" | grep -qi 'empty' \
  || fail "the dead-source refusal did not say why ($out)"
[ -f "$T/nascache/Docs/keep.txt" ] || fail "the guard let cache data be lost"

pass "PROVIDER=none: gates, syncs, seeds and refuses, with no rclone"
