#!/bin/sh
# unit.t - UNIT tests: functions called directly with controlled input.
#
# Every other test here is an integration test -- drive the whole command
# against stubs and inspect what it wrote. Those prove the pieces fit, but they
# are slow, and they cannot cheaply reach an edge case (an empty value, a
# hidden file, a tilde, a pattern with a slash). Several real bugs in this
# project lived exactly there: `${v#~/}` tilde-expanding the PATTERN, a
# formatted-date comparison that a timezone broke, an unmounted mountpoint
# passing an existence test.
#
# These run in milliseconds, so the edge cases can be exhaustive.
. "$(dirname "$0")/lib.sh"
harness_init unit

export CHARON_LIBEXEC=$HERE/libexec
export CHARON_LIB_ONLY=1
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_SOURCES_DIR=$T/cfg/sources.d
export CHARON_TRAITS_DIR=$T/traits
export CHARON_REMOTE=testremote
export CHARON_MOUNT=$T/mnt
export CHARON_CACHE=$T/cache
mkdir -p "$T/cfg/profiles.d" "$T/cfg/sources.d" "$T/traits"

# shellcheck disable=SC1090
. "$CHARON_LIBEXEC/charon-sync"

_is() {   # <got> <want> <label>
  [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"
}

#### profile_get: literal reads, and the tilde trap ####
cat > "$T/cfg/profiles.d/p.conf" <<EOF
SUBTREE=Docs
LINKISH=~/somewhere
EMPTY=
SPACED=a value with spaces
IGNORE=one
IGNORE=two/three
EOF
_is "$(profile_get p SUBTREE)" "Docs"                 "profile_get plain"
_is "$(profile_get p MISSING)" ""                     "profile_get absent key"
_is "$(profile_get p EMPTY)"   ""                     "profile_get empty value"
_is "$(profile_get p SPACED)"  "a value with spaces"  "profile_get keeps spaces"
# THE TILDE TRAP: the strip pattern must be QUOTED, or the shell expands the
# ~/ in the pattern to $HOME/ and it never matches the literal prefix. That bug
# put a working link at $HOME/~/... on a live box.
_is "$(profile_get p LINKISH)" "$T/somewhere"         "profile_get expands ~/"
_is "$(profile_get nosuch KEY)" ""                    "profile_get absent file"
# repeatable keys: get takes the FIRST, get_all takes all
_is "$(profile_get p IGNORE)" "one"                   "profile_get takes first"
_is "$(profile_get_all p IGNORE | tr '\n' ',')" "one,two/three," \
    "profile_get_all returns every value"

#### which source a profile names ####
printf 'SOURCE=nas:Docs\n'  > "$T/cfg/profiles.d/a.conf"
printf 'SOURCE=nas\n'       > "$T/cfg/profiles.d/b.conf"
printf 'SUBTREE=Legacy\n'   > "$T/cfg/profiles.d/c.conf"
printf 'INTERVAL=5m\n'      > "$T/cfg/profiles.d/d.conf"
printf 'SOURCE=nas:a/b/c\n' > "$T/cfg/profiles.d/e.conf"
_is "$(profile_source_name a)" "nas"     "SOURCE=src:sub -> source"
_is "$(profile_subtree a)"     "Docs"    "SOURCE=src:sub -> subtree"
_is "$(profile_source_name b)" "nas"     "SOURCE=src (whole source)"
_is "$(profile_subtree b)"     ""        "SOURCE=src has no subtree"
_is "$(profile_source_name c)" "default" "legacy SUBTREE= means default"
_is "$(profile_subtree c)"     "Legacy"  "legacy SUBTREE= subtree"
_is "$(profile_source_name d)" ""        "no SOURCE and no SUBTREE: no source"
_is "$(profile_subtree e)"     "a/b/c"   "a subtree may contain slashes"

#### source_get: the implicit default, and overrides ####
_is "$(source_get default MOUNT)"      "$T/mnt"      "implicit default MOUNT"
_is "$(source_get default CACHE_ROOT)" "$T/cache"    "implicit default CACHE"
_is "$(source_get default REMOTE)"     "testremote"  "implicit default REMOTE"
_is "$(source_get default PROVIDER)"   "rclone"      "implicit default PROVIDER"
_is "$(source_get nosuch MOUNT)"       ""            "undefined source is empty"
printf 'MOUNT=~/declared\nPROVIDER=none\n' > "$T/cfg/sources.d/d2.conf"
_is "$(source_get d2 MOUNT)"    "$T/declared" "declared MOUNT expands ~/"
_is "$(source_get d2 PROVIDER)" "none"        "declared PROVIDER"
_is "$(source_get d2 REMOTE)"   ""            "no REMOTE on a none source"
# a file may override the implicit default, key by key
printf 'MOUNT=/over/ridden\n' > "$T/cfg/sources.d/default.conf"
_is "$(source_get default MOUNT)"  "/over/ridden" "default.conf overrides"
_is "$(source_get default REMOTE)" "testremote"   "unset keys still derive"
rm -f "$T/cfg/sources.d/default.conf"

#### dir_has_entries: hidden files count, empty and absent do not ####
mkdir -p "$T/d_empty" "$T/d_hidden" "$T/d_plain"
: > "$T/d_plain/f"; : > "$T/d_hidden/.hidden"
dir_has_entries "$T/d_plain"   || fail "a plain file should count"
dir_has_entries "$T/d_hidden"  || fail "a HIDDEN file should count (it is data)"
dir_has_entries "$T/d_empty"   && fail "an empty dir must not count" || :
dir_has_entries "$T/nonexistent" && fail "an absent dir must not count" || :

#### traits -> unison prefs: the derivation that decides correctness ####
_traits() { printf '%s\n' "$@" > "$T/traits/s"; }
_traits CASE=sensitive TIMES=settable PERMS=posix LINKS=yes FSTYPE=ext4
out=$(render_prf_traits s)
printf '%s\n' "$out" | grep -qx 'ignorecase = false' || fail "POSIX: ignorecase"
printf '%s\n' "$out" | grep -qx 'times = true'       || fail "POSIX: times"
printf '%s\n' "$out" | grep -q 'perms = 0' \
  && fail "a POSIX source must keep its permissions" || :
printf '%s\n' "$out" | grep -q 'links = false' \
  && fail "a POSIX source must keep its symlinks" || :
printf '%s\n' "$out" | grep -q 'ignoreinodenumbers' \
  && fail "a POSIX source must not ignore stable inodes" || :

# the cloud shape: every one of fat's components, derived not assumed
_traits CASE=sensitive TIMES=settable PERMS=none LINKS=no FSTYPE=fuseblk
out=$(render_prf_traits s)
for want in 'ignorecase = false' 'times = true' 'perms = 0' \
            'dontchmod = true' 'links = false' 'ignoreinodenumbers = true'; do
  printf '%s\n' "$out" | grep -qx "$want" || fail "cloud shape missing: $want"
done
printf '%s\n' "$out" | grep -q '^fat = ' \
  && fail "the fat shorthand is back; components must be explicit" || :

# a case-INSENSITIVE backend (SMB, FAT): the one charon must not get wrong
_traits CASE=insensitive TIMES=settable PERMS=none LINKS=no FSTYPE=cifs
render_prf_traits s | grep -qx 'ignorecase = true' \
  || fail "an insensitive backend must fold case"

# a backend that cannot carry mtimes
_traits CASE=sensitive TIMES=fixed PERMS=posix LINKS=yes FSTYPE=ext4
render_prf_traits s | grep -qx 'times = false' \
  || fail "a backend with fixed mtimes must not be told to propagate them"

# missing traits: the safe default is the SENSITIVE one, because folding case
# on a case-sensitive backend silently merges two distinct files.
: > "$T/traits/s"
render_prf_traits s | grep -qx 'ignorecase = false' \
  || fail "with no CASE trait the default must be case-SENSITIVE"

#### paths_overlap: catastrophes, and things that merely look like them ####
paths_overlap /a/b /a/b       || fail "identical paths must overlap"
paths_overlap /a/b/ /a/b      || fail "a trailing slash must not hide equality"
paths_overlap /a /a/b         || fail "a parent contains its child"
paths_overlap /a/b /a         || fail "overlap is symmetric"
paths_overlap /a/b /a/c       && fail "siblings do not overlap" || :
# the near-miss a naive prefix test gets WRONG: /a/bc is not in /a/b
paths_overlap /a/b /a/bc      && fail "/a/bc is not inside /a/b" || :
paths_overlap /a/bcd /a/b     && fail "prefix is not containment" || :
paths_overlap "" /a           && fail "an empty path cannot overlap" || :

#### severity aggregation: `sync all` must report the WORST outcome ####
# Reporting the LAST profile's result instead would let a fault hide behind a
# later success, which is the whole reason this aggregates by severity.
# Folds the REAL worse_of, not a reimplementation of it.
_agg() {
  _rc=0
  for _pr in "$@"; do _rc=$(worse_of "$_rc" "$_pr"); done
  printf '%s' "$_rc"
}
_is "$(_agg 0 0)"    "0"  "all success aggregates to success"
_is "$(_agg 0 75)"   "75" "a skip beats success"
_is "$(_agg 75 0)"   "75" "a skip is not erased by a later success"
_is "$(_agg 0 1)"    "1"  "a fault beats success"
_is "$(_agg 1 0)"    "1"  "a fault is not erased by a later success"
_is "$(_agg 75 1)"   "1"  "a fault outranks a skip"
_is "$(_agg 1 75)"   "1"  "a fault is not downgraded by a later skip"
_is "$(_agg 0 75 1)" "1"  "worst-of-three"

#### the PROBE primitives: measurement code, tested by measuring ####
# These decide every backend-derived pref, so a wrong answer here is a wrong
# profile. One of them has already shipped a real bug: probe_times compared a
# FORMATTED date, and `touch -d` read the string as UTC, so a perfectly good
# filesystem was reported as unable to carry mtimes. That is why the timezone
# case below exists.
( CHARON_LIB_ONLY=1 . "$CHARON_LIBEXEC/charon-source" ) 2>/dev/null \
  || fail "charon-source could not be sourced for unit testing"
# shellcheck disable=SC1090
. "$CHARON_LIBEXEC/charon-source"

mkdir -p "$T/probe"
_is "$(probe_case "$T/probe")"  "sensitive" "a local fs is case-sensitive"
_is "$(probe_perms "$T/probe")" "posix"     "a local fs carries permissions"
_is "$(probe_links "$T/probe")" "yes"       "a local fs supports symlinks"
_is "$(probe_times "$T/probe")" "settable"  "a local fs carries mtimes"
_is "$(probe_mountpoint "$T/probe")" "no"   "a plain dir is not a mountpoint"

# THE TIMEZONE REGRESSION. A formatted-date comparison broke here once; epoch
# seconds are timezone-free, so the answer must not depend on TZ at all.
for _tz in UTC America/New_York Asia/Kathmandu Pacific/Kiritimati; do
  _is "$(TZ=$_tz probe_times "$T/probe")" "settable" "probe_times under TZ=$_tz"
done

# every probe must clean up after itself: leftovers inside a source would be
# litter on someone's remote.
_left=$(ls -A "$T/probe" | wc -l)
_is "$_left" "0" "the probes left files behind"

# a source with no PROVIDER is 'none', not empty: charon must never treat an
# unspecified provider as rclone and go looking for a remote.
printf 'MOUNT=/x\nCACHE_ROOT=/y\n' > "$T/cfg/sources.d/np.conf"
_is "$(source_provider np)" "none" "an unset PROVIDER defaults to none"

pass "parsing, tildes, dir tests, trait derivation, probes, severity"
