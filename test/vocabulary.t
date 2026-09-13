#!/bin/sh
# vocabulary.t - the config vocabulary: a SOURCE names the tree and its cache,
# a PROFILE names a subtree of one plus its policy, and the three Tier 1 knobs
# (IGNORE / CONFLICT / DELETE) are translated into unison HERE so that profiles
# never have to speak unison. Also pins the two compatibility promises: the
# legacy SUBTREE= shorthand keeps working, and a profile that sets NONE of the
# new knobs renders exactly what it rendered before, so an existing install
# does not drift the moment this lands.
. "$(dirname "$0")/lib.sh"
harness_init vocabulary

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
export CHARON_REMOTE=testremote
CFG=$XDG_CONFIG_HOME/charon
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d"
for s in sudo systemctl systemd-run rclone unison mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"

_install() {
  PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync install >/dev/null 2>&1 \
    || fail "sync install errored"
}

# --- an EXPLICIT source, and a profile pointing at it ---
cat > "$CFG/sources.d/nas.conf" <<EOF
MOUNT=$T/mnt/nas
CACHE_ROOT=$T/cache/nas
PROVIDER=none
EOF
printf 'SOURCE=nas:Docs\n' > "$CFG/profiles.d/docs.conf"
_install
prf=$T/.unison/charon-docs.prf
grep -q "^root = $T/mnt/nas/Docs\$" "$prf" \
  || fail "source MOUNT not used"
grep -q "^root = $T/cache/nas/Docs\$" "$prf" \
  || fail "source CACHE_ROOT not used"

# --- two profiles SHARING one source: the whole reason sources are separate ---
printf 'SOURCE=nas:Pics\n' > "$CFG/profiles.d/pics.conf"
_install
grep -q "^root = $T/mnt/nas/Pics\$" "$T/.unison/charon-pics.prf" \
  || fail "a second profile did not resolve the shared source"

# --- the IMPLICIT default source: no sources.d file, legacy SUBTREE= ---
rm -f "$CFG/profiles.d/pics.conf" "$CFG/profiles.d/docs.conf"
printf 'SUBTREE=Docs\n' > "$CFG/profiles.d/legacy.conf"
_install
lprf=$T/.unison/charon-legacy.prf
grep -q "^root = $T/testremote/Docs\$" "$lprf" \
  || fail "implicit default mount"
grep -q "^root = $T/.testremote/Docs\$" "$lprf" \
  || fail "implicit default cache"

# COMPATIBILITY: with no new knobs set, the render must be what it always was.
grep -q "^prefer = $T/testremote/Docs\$" "$lprf" \
  || fail "default prefer changed"
grep -q '^# the live mount is canonical$' "$lprf" \
  || fail "default render drifted (an existing install would need reinstalling)"
grep -q '^nodeletion' "$lprf" \
  && fail "nodeletion emitted without DELETE=never" || :

# --- CONFLICT ---
printf 'SUBTREE=Docs\nCONFLICT=local\n' > "$CFG/profiles.d/legacy.conf"
_install
grep -q "^prefer = $T/.testremote/Docs\$" "$lprf" \
  || fail "CONFLICT=local did not prefer the cache"
printf 'SUBTREE=Docs\nCONFLICT=newer\n' > "$CFG/profiles.d/legacy.conf"
_install
grep -q '^prefer = newer$' "$lprf" || fail "CONFLICT=newer not mapped"

# --- DELETE=never: BOTH roots protected, or it is not a promise ---
printf 'SUBTREE=Docs\nDELETE=never\n' > "$CFG/profiles.d/legacy.conf"
_install
grep -q "^nodeletion = $T/testremote/Docs\$" "$lprf" \
  || fail "source root not guarded"
grep -q "^nodeletion = $T/.testremote/Docs\$" "$lprf" \
  || fail "cache root not guarded"

# --- IGNORE: repeatable, and translated without the profile speaking unison ---
printf 'SUBTREE=Docs\nIGNORE=*.tmp\nIGNORE=Archive/scratch\n' \
  > "$CFG/profiles.d/legacy.conf"
_install
grep -q '^ignore = Name \*\.tmp$' "$lprf" \
  || fail "a bare pattern should become a Name rule"
grep -q '^ignore = Path Archive/scratch$' "$lprf" \
  || fail "a pattern with a slash should become a Path rule"
grep -c '^ignore = ' "$lprf" | grep -qx 3 \
  || fail "expected 3 ignore lines (2 configured + charon's own temp rule)"

# --- Tier 2: a verbatim include, emitted only when the file exists ---
# unison errors on a missing include, so it must not be emitted unconditionally.
printf 'SUBTREE=Docs\n' > "$CFG/profiles.d/legacy.conf"
_install
grep -q '^include ' "$lprf" && fail "include emitted with no .prf.local" || :
printf 'fastcheck = false\n' > "$T/.unison/charon-legacy.prf.local"
_install
grep -q '^include charon-legacy\.prf\.local$' "$lprf" \
  || fail "Tier 2 .prf.local was not included once it existed"
rm -f "$T/.unison/charon-legacy.prf.local"

# --- install must need NO privilege when the package is already there ---
# It used to run `sudo true` unconditionally, which made every routine prf
# regeneration a sudo handoff on a box that needed no privilege at all. With
# no sudo on PATH, install must still succeed.
rm -f "$T/bin/sudo"
env PATH="$T/bin:/usr/bin:/bin" HOME="$T" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  CHARON_REMOTE=testremote sh "$HERE/bin/charon" sync install >/dev/null 2>&1 \
  || fail "install needed privilege it should not have needed"

pass "sources, the implicit default, and the three Tier 1 knobs"
