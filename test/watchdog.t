#!/bin/sh
# watchdog.t - the DEAD-MOUNT guard. A FUSE mount that lost its backend still
# answers as a directory and presents an EMPTY one; under a two-way sync that
# is indistinguishable from "the remote deleted everything", so the pass
# propagates the emptiness as deletions. This is not hypothetical: unison
# really did delete Images/Screenshots/screenshot_01.png from the remote.
#
# The guard is ASYMMETRIC and this test pins both halves: source-empty over a
# populated cache is REFUSED, while source-full over an empty cache is a FIRST
# SEED and must be allowed, or no new profile could ever populate.
. "$(dirname "$0")/lib.sh"
harness_init watchdog

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
export CHARON_REMOTE=testremote          # -> ~/testremote + ~/.testremote

M=$T/testremote                          # the "mount"
C=$T/.testremote                         # the cache
mkdir -p "$T/bin" "$T/.cache" "$XDG_CONFIG_HOME/charon/profiles.d"
printf 'SUBTREE=Docs\n' > "$XDG_CONFIG_HOME/charon/profiles.d/docs.conf"

# stubs: everything the gate consults says "fine", so the ONLY thing deciding
# the outcome is the emptiness comparison under test.
for s in systemctl unison mountpoint rclone; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done

_run() { PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync run docs 2>&1; }

# --- the DEAD-MOUNT signature: source subtree empty, cache populated ---
rm -rf "$M" "$C"; mkdir -p "$M/Docs" "$M/other" "$C/Docs"
echo data > "$C/Docs/keep.txt"           # cache has content, source does not
out=$(_run); rc=$?
[ "$rc" = 0 ] && fail "empty source over a populated cache was ALLOWED (rc=0)"
[ "$rc" = 75 ] && fail "dead mount reported as a routine SKIP, not a fault"
printf '%s\n' "$out" | grep -qi 'empty' \
  || fail "refusal did not say the source was empty (got: $out)"
printf '%s\n' "$out" | grep -qi 'refus' \
  || fail "refusal did not announce itself as a refusal (got: $out)"
[ -f "$C/Docs/keep.txt" ] || fail "the guard let the cache file be destroyed"

# --- FIRST SEED: source populated, cache empty -> must be allowed ---
rm -rf "$M" "$C"; mkdir -p "$M/Docs" "$C/Docs"
echo data > "$M/Docs/new.txt"
out=$(_run); rc=$?
[ "$rc" = 0 ] || fail "first seed (full source, empty cache) was refused rc=$rc"

# --- a wholly empty source root is a dead mount too, whatever the subtree ---
rm -rf "$M" "$C"; mkdir -p "$M" "$C/Docs"
echo data > "$C/Docs/keep.txt"
out=$(_run); rc=$?
[ "$rc" = 0 ] && fail "an entirely empty source root was ALLOWED"
printf '%s\n' "$out" | grep -qi 'dead' \
  || fail "empty source root did not name the dead-mount cause (got: $out)"

# --- both populated: an ordinary pass ---
rm -rf "$M" "$C"; mkdir -p "$M/Docs" "$C/Docs"
echo data > "$M/Docs/a.txt"; echo data > "$C/Docs/b.txt"
out=$(_run); rc=$?
[ "$rc" = 0 ] || fail "an ordinary populated pass was refused rc=$rc"

pass "dead-mount source refused; first seed still allowed"
