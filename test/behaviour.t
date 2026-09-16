#!/bin/sh
# behaviour.t - run REAL unison against a charon-generated profile and assert
# what actually happens to the files.
#
# THE GAP THIS CLOSES. Every other test asserts the CONFIG charon writes: that
# the prf contains `nodeletion = ...`, that it contains `ignore = Name ...`.
# None of them asserts that a deletion is actually prevented, or that an
# ignored path is actually skipped. That distinction is not academic here: the
# worst bug this project had was precisely a correct-looking prf whose real
# behaviour differed. `fat = true` silently implied ignorecase, the prf looked
# fine, and unison refused an entire profile for weeks. A test asserting the
# prf line would have passed throughout.
#
# So these tests do the slow thing: two real trees, a real unison, and
# assertions about FILES.
. "$(dirname "$0")/lib.sh"
harness_init behaviour

command -v unison >/dev/null 2>&1 || skip "unison not installed"

export HOME=$T
export CHARON_LIBEXEC=$HERE/libexec
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/src/D" "$T/cache/D"
for s in systemctl systemd-run mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

cat > "$CFG/sources.d/s.conf" <<EOF
PROVIDER=none
MOUNT=$T/src
CACHE_ROOT=$T/cache
EOF

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg sh "$HERE/bin/charon" "$@"
}
# a pass, then settle: unison needs an established archive before a DELETION is
# a deletion rather than a first-sight file.
_sync() { _c sync docs >/dev/null 2>&1; }
_reset() {
  rm -rf "$T/src" "$T/cache" "$T/uni" "$T/st"
  mkdir -p "$T/src/D" "$T/cache/D"
}

#### DELETE=propagate: the default really does mirror a deletion ####
# Several files on purpose. Removing the ONLY file empties the replica, which
# confirmbigdel refuses -- correct, but it tests the safety net rather than the
# delete policy. That is asserted separately below.
_reset
printf 'SOURCE=s:D\n' > "$CFG/profiles.d/docs.conf"
for f in one two three four; do echo data > "$T/src/D/$f.txt"; done
_c install >/dev/null 2>&1 || fail "install failed"
_sync
[ -f "$T/cache/D/one.txt" ] || fail "the first pass did not populate the cache"
rm -f "$T/src/D/one.txt"
_sync
[ -f "$T/cache/D/one.txt" ] \
  && fail "DELETE=propagate did not mirror the deletion" || :
[ -f "$T/cache/D/two.txt" ] || fail "an unrelated file was destroyed"

#### confirmbigdel: emptying a whole replica is REFUSED, not obeyed ####
# Tier 0, and the last line of defence against the failure mode that started
# this project: a source that has gone empty being read as "delete everything".
_reset
printf 'SOURCE=s:D\n' > "$CFG/profiles.d/docs.conf"
for f in a b c; do echo data > "$T/src/D/$f.txt"; done
_c install >/dev/null 2>&1 || fail "install failed (confirmbigdel)"
_sync
rm -f "$T/src/D"/*.txt          # the whole subtree, gone
_sync                            # charon's own empty-source guard fires first
for f in a b c; do
  [ -f "$T/cache/D/$f.txt" ] \
    || fail "emptying the source destroyed the cache copy of $f.txt"
done


#### DELETE=never: a deletion is NOT mirrored, and the file comes BACK ####
# This is the knob's whole promise: an accidental rm cannot reach the far side.
_reset
printf 'SOURCE=s:D\nDELETE=never\n' > "$CFG/profiles.d/docs.conf"
echo data > "$T/src/D/precious.txt"
_c install >/dev/null 2>&1 || fail "install failed (DELETE=never)"
_sync
[ -f "$T/cache/D/precious.txt" ] || fail "first pass did not populate"
rm -f "$T/cache/D/precious.txt"          # an accidental local rm
_c sync docs >/dev/null 2>&1; _rc1=$?
[ -f "$T/src/D/precious.txt" ] \
  || fail "DELETE=never let a local rm destroy the SOURCE copy"
# MEASURED behaviour, and the docs said otherwise until this test was written:
# nodeletion does not restore the missing copy. It makes the path an
# unresolved conflict, and the profile FAULTS until a human settles it. That
# is defensible -- you asked for deletions never to propagate, so charon will
# not guess which side you meant -- but it must be documented as what it is.
[ "$_rc1" = 0 ] \
  && fail "DELETE=never silently accepted a deletion it was told to refuse" || :
_c sync docs >/dev/null 2>&1 \
  && fail "the conflict resolved itself; it must persist until settled" || :
[ -f "$T/src/D/precious.txt" ] || fail "the source copy must keep surviving"

#### IGNORE: an ignored path is really never copied ####
_reset
printf 'SOURCE=s:D\nIGNORE=*.tmp\nIGNORE=skipme/deep\n' \
  > "$CFG/profiles.d/docs.conf"
mkdir -p "$T/src/D/skipme/deep" "$T/src/D/normal"
echo a > "$T/src/D/real.txt"
echo b > "$T/src/D/scratch.tmp"
echo c > "$T/src/D/skipme/deep/buried.txt"
echo d > "$T/src/D/normal/fine.txt"
_c install >/dev/null 2>&1 || fail "install failed (IGNORE)"
_sync
[ -f "$T/cache/D/real.txt" ]        || fail "a normal file was not synced"
[ -f "$T/cache/D/normal/fine.txt" ] || fail "a normal subdir was not synced"
[ -e "$T/cache/D/scratch.tmp" ] \
  && fail "IGNORE=*.tmp did not actually exclude the file" || :
[ -e "$T/cache/D/skipme/deep/buried.txt" ] \
  && fail "IGNORE=skipme/deep did not actually exclude the path" || :

#### CONFLICT: who wins, and WHERE the losing copy lands ####
# The second question matters as much as the first. copyonconflict keeps the
# overwritten version, and which SIDE it lands on decides whether resolving a
# conflict quietly writes to the remote -- the thing this project exists to
# avoid. The docs make specific claims here; these assert them.
_conflict_setup() {   # <CONFLICT value>
  _reset
  printf 'SOURCE=s:D\nCONFLICT=%s\n' "$1" > "$CFG/profiles.d/docs.conf"
  echo original > "$T/src/D/both.txt"
  echo filler   > "$T/src/D/other.txt"
  _c install >/dev/null 2>&1 || fail "install failed (CONFLICT=$1)"
  _sync
  echo from-source > "$T/src/D/both.txt"
  echo from-cache  > "$T/cache/D/both.txt"
  sleep 1
  _sync
}
_copies() { ls "$1" | grep -c 'conflict_on' || :; }

# remote (the default): the SOURCE wins and the copy stays LOCAL, so resolving
# a conflict costs the remote nothing.
_conflict_setup remote
_is=$(cat "$T/src/D/both.txt")
[ "$_is" = from-source ] \
  || fail "CONFLICT=remote: the source should win, got '$_is'"
[ "$(_copies "$T/cache/D")" -ge 1 ] \
  || fail "CONFLICT=remote: the overwritten local copy was not kept"
[ "$(_copies "$T/src/D")" = 0 ] \
  || fail "CONFLICT=remote wrote a conflict copy to the REMOTE"

# local: the cache wins, and the copy DOES land on the remote. Documented as a
# caveat; assert it so the caveat cannot quietly become false.
_conflict_setup local
_is=$(cat "$T/src/D/both.txt")
[ "$_is" = from-cache ] || fail "CONFLICT=local: cache should win, got '$_is'"
[ "$(_copies "$T/src/D")" -ge 1 ] \
  || fail "CONFLICT=local should leave the overwritten copy on the remote"

# newer, cache side newer: the same remote-write caveat applies, which the
# documentation did not mention until this test was written.
_reset
printf 'SOURCE=s:D\nCONFLICT=newer\n' > "$CFG/profiles.d/docs.conf"
echo original > "$T/src/D/both.txt"; echo filler > "$T/src/D/other.txt"
_c install >/dev/null 2>&1 || fail "install failed (CONFLICT=newer)"
_sync
echo from-source > "$T/src/D/both.txt"
touch -d @1000000000 "$T/src/D/both.txt"
echo from-cache > "$T/cache/D/both.txt"
touch -d @2000000000 "$T/cache/D/both.txt"
_sync
[ "$(cat "$T/src/D/both.txt")" = from-cache ] \
  || fail "CONFLICT=newer did not let the newer side win"
[ "$(_copies "$T/src/D")" -ge 1 ] \
  || fail "CONFLICT=newer: expected the loser copy on the remote when the
    cache wins -- if this changed, the docs need updating"

#### a SUBTREE with a space really does reconcile ####
# Not hypothetical: the Drive this was built for contains "Google Earth". The
# name VALIDATION added 2026-09-16 deliberately does not extend to subtrees --
# a profile NAME becomes a systemd unit and must be restricted, a subtree is
# just a path and must not be. This asserts that boundary behaviourally rather
# than trusting that the prf looked right: unison reads the rest of a prf line
# as the value, so an unquoted space is correct there and quoting it would be
# the bug.
_reset
printf 'SOURCE=s:D\n' > "$CFG/profiles.d/docs.conf"
mkdir -p "$T/src/D/Google Earth"
echo mapped > "$T/src/D/Google Earth/place.kml"
_c install >/dev/null 2>&1 || fail "install failed (space subtree)"
_sync
[ -f "$T/cache/D/Google Earth/place.kml" ] \
  || fail "a path with a space was not reconciled"

#### the charon-generated profile really does ignore unison's own temps ####
# The bug that started all of this: a stranded .unison.*.tmp being treated as
# ordinary content and REPLICATED. Assert it is not copied.
_reset
printf 'SOURCE=s:D\n' > "$CFG/profiles.d/docs.conf"
echo real > "$T/src/D/f.txt"
printf 'stranded\n' > "$T/src/D/.unison.f.txt.abc123.unison.tmp"
_c install >/dev/null 2>&1 || fail "install failed (temps)"
_sync
[ -f "$T/cache/D/f.txt" ] || fail "the real file was not synced"
[ -e "$T/cache/D/.unison.f.txt.abc123.unison.tmp" ] \
  && fail "a stranded unison temp was REPLICATED -- the original bug is back" \
  || :

pass "real unison: delete policy, ignore, conflict, and temp exclusion"
