#!/bin/sh
# sweep-config.t - the user owns whether the daily sweep runs, and how old a
# temp must be before it goes.
#
# THE GAP THIS CLOSES. The daily sweep shipped enabled by default with NO way to
# turn it off. `systemctl --user disable charon-sweep.timer` made `charon check`
# FAIL forever, and an integrator that turns a non-zero check into drift (tackup
# does) then runs apply, which re-enables it -- so a deliberate opt-out was
# silently reverted on every provision sweep. Not a nag: a fight the user loses.
# That is the litter-is-not-drift mistake one level up, and it matters most for
# an outside user, who did not choose charon's defaults.
#
# Two properties, and both directions of each:
#   1. SWEEP=off REMOVES the units (not merely "stops enabling" them: a
#      leftover enabled timer would keep deleting from the user's remote after
#      they asked it not to) and check must report that state CLEAN.
#   2. CRUMB_AGE_MIN is honoured from config, so the TIMED run honours it too --
#      it used to be env-only and the generated unit baked nothing, so setting
#      it in a shell changed nothing about what actually ran.
. "$(dirname "$0")/lib.sh"
harness_init sweep-config

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_TRAITS_DIR=$T/st
export CHARON_STATE=$T/state
export UNISON_DIR=$T/uni
export XDG_CONFIG_HOME=$T/xdg
CFG=$T/cfg
SD=$T/xdg/systemd/user
WANTS=$T/xdg/systemd/user/timers.target.wants
mkdir -p "$CFG/profiles.d" "$CFG/sources.d" "$T/st" "$T/uni" "$T/.cache" \
         "$T/bin" "$T/state" "$SD" "$WANTS" "$T/src/D" "$T/cache/D"

# A systemctl that MODELS enable/disable/is-enabled, because a stub that just
# exits 0 answers "enabled" to everything and makes every assertion here
# unfalsifiable. Verified against the real tool on 2026-09-26: real
# `systemctl --user is-enabled <missing unit>` prints not-found and exits 4, so
# removing the unit file must make this say no. `-L` not `-e`, because -e
# FOLLOWS a symlink and is false for a dangling one.
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
SD=$SD; W=$WANTS
a=
for x in "\$@"; do
  case "\$x" in --user|--now|-q|--quiet|--no-legend|--all) ;; *) a="\$a \$x" ;;
  esac
done
# shellcheck disable=SC2086
set -- \$a
case "\${1:-}" in
  enable)  shift; for u in "\$@"; do
             [ -f "\$SD/\$u" ] || exit 1
             ln -sfn "\$SD/\$u" "\$W/\$u"; done ;;
  disable) shift; for u in "\$@"; do rm -f "\$W/\$u"; done ;;
  is-enabled) { [ -L "\$W/\$2" ] && [ -f "\$SD/\$2" ]; } || exit 4 ;;
  is-active)  { [ -L "\$W/\$2" ] && [ -f "\$SD/\$2" ]; } || exit 3 ;;
  list-unit-files) printf 'charon-sync@.service enabled\n' ;;
  show) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/bin/systemctl"
for s in systemd-run mountpoint unison; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"; done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

# ASSERT THE HARNESS IS HONEST before asserting anything about charon. A stub
# whose is-enabled cannot say "no" would make every [OK] below meaningless.
: > "$SD/probe.timer"
PATH="$T/bin:$PATH" systemctl --user enable probe.timer
PATH="$T/bin:$PATH" systemctl --user is-enabled probe.timer \
  || fail "the systemctl stub says a unit it just enabled is NOT enabled"
rm -f "$SD/probe.timer"
PATH="$T/bin:$PATH" systemctl --user is-enabled probe.timer \
  && fail "the systemctl stub reports a unit with NO FILE as enabled; the real
  tool prints not-found and exits 4, so every assertion below would be
  unfalsifiable"
rm -f "$WANTS/probe.timer"

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

_c() { PATH="$T/bin:/usr/bin:/bin" sh "$HERE/libexec/charon-sync" "$@"; }

# ----------------------------------------------------------------- part 1 ----
# THE DEFAULT IS ON. A user who has never heard of .unison.*.unison.tmp cannot
# be expected to opt in to collecting it, so an install with no config at all
# must leave the box tidy by itself.
[ -f "$CFG/charon.conf" ] && fail "the test wrote a config before part 1"
_c install >/dev/null 2>&1 || fail "install failed with no global config"
[ -f "$SD/charon-sweep.service" ] || fail "default install wrote no sweep unit"
[ -f "$SD/charon-sweep.timer" ] || fail "default install wrote no sweep timer"
[ -L "$WANTS/charon-sweep.timer" ] \
  || fail "default install did not ENABLE the sweep timer"
_c check >"$T/chk" 2>&1 || :
grep -q '\[OK\].*charon-sweep.timer enabled' "$T/chk" \
  || fail "check did not confirm the sweep timer: $(cat "$T/chk")"

# ----------------------------------------------------------------- part 2 ----
# SWEEP=off REMOVES the machinery, and check calls that CLEAN.
printf 'SWEEP=off\n' > "$CFG/charon.conf"
_c install 2>"$T/offerr" >/dev/null || fail "install failed with SWEEP=off"
[ -e "$SD/charon-sweep.timer" ] \
  && fail "SWEEP=off left the timer file; 'off' must REMOVE it, or it keeps
  deleting from the user's remote after they asked it not to"
[ -e "$SD/charon-sweep.service" ] && fail "SWEEP=off left the sweep service"
# -L AS WELL AS -e: `disable` removes the wants symlink, but if only the unit
# FILE were removed the symlink would remain DANGLING -- and -e follows a
# symlink, so it is FALSE for one. This assertion could not see a leftover
# enablement
# until it asked -L, which is the same trap that once hid a dangling unit link
# here. Found by mutation: dropping the `systemctl disable` survived without it.
{ [ -L "$WANTS/charon-sweep.timer" ] || [ -e "$WANTS/charon-sweep.timer" ]; } \
  && fail "SWEEP=off left the timer ENABLED (a wants symlink survives, so the
  timer systemd has already loaded was never stopped)"
# AND IT MUST NOT NAG. Re-running enable for a unit that was deliberately
# removed fails every time, and a warning that fires on every install is a
# warning nobody reads -- this project has already paid for that once.
grep -q 'could not enable charon-sweep' "$T/offerr" \
  && fail "a SWEEP=off install warned about failing to enable the timer it was
  asked not to install; that warning would fire on every single install"
_c check >"$T/chk" 2>&1; _offrc=$?
[ "$_offrc" = 0 ] \
  || fail "check FAILED on a deliberate SWEEP=off ($_offrc): an integrator
  turns that into drift and its apply re-enables the timer, so the user's
  choice is reverted on every provision sweep. Output: $(cat "$T/chk")"
grep -q '\[OK\].*SWEEP=off' "$T/chk" \
  || fail "check did not say the sweep is off BY CONFIG: $(cat "$T/chk")"
# The verb still works by hand -- 'off' is about the schedule, not the feature.
_c sweep >/dev/null 2>&1 \
  || fail "'charon sweep' stopped working with SWEEP=off; the setting governs
  the TIMER, not whether a human can ask for a sweep"

# ...and the OTHER direction is what drift means here: artifacts surviving off.
: > "$SD/charon-sweep.timer"
_c check >"$T/chk" 2>&1 && fail "check passed with SWEEP=off while the timer
  file was still installed; that is the one thing that IS drift in this state"
grep -q '\[FAIL\].*SWEEP=off' "$T/chk" \
  || fail "check did not name SWEEP=off as the reason: $(cat "$T/chk")"
rm -f "$SD/charon-sweep.timer"

# ----------------------------------------------------------------- part 3 ----
# AND BACK. A mode switch has to be reversible, and idempotent in both modes.
printf 'SWEEP=daily\n' > "$CFG/charon.conf"
_c install >/dev/null 2>&1 || fail "install failed switching back to daily"
[ -f "$SD/charon-sweep.timer" ] \
  || fail "switching back did not restore the timer"
[ -L "$WANTS/charon-sweep.timer" ] || fail "switching back did not re-enable it"
_c install >/dev/null 2>&1 || fail "a second daily install failed"
_c check >/dev/null 2>&1 || fail "check failed after a repeat daily install"
printf 'SWEEP=off\n' > "$CFG/charon.conf"
_c install >/dev/null 2>&1 && _c install >/dev/null 2>&1 \
  || fail "a repeated SWEEP=off install failed"
_c check >/dev/null 2>&1 || fail "check failed after a repeat off install"

# An unrecognised value behaves as DAILY and says so: leaving litter on someone
# else's remote is the worse failure, and a typo must not quietly disable a
# safety feature.
printf 'SWEEP=yes-please\n' > "$CFG/charon.conf"
_c install 2>"$T/err" >/dev/null || fail "install failed on a bad SWEEP value"
[ -f "$SD/charon-sweep.timer" ] \
  || fail "an unrecognised SWEEP value silently DISABLED the sweep; it must
  fall back to daily"
grep -q "SWEEP='yes-please'" "$T/err" \
  || fail "nothing warned about the unrecognised SWEEP value: $(cat "$T/err")"

# ----------------------------------------------------------------- part 4 ----
# CRUMB_AGE_MIN comes from CONFIG, so the TIMED run honours it. It used to be
# env-only while the generated unit baked nothing, so a user setting it in a
# shell changed nothing about what actually ran.
CHARON_LIB_ONLY=1 . "$HERE/libexec/charon-sync"
_self=$HERE/libexec/charon-sync

printf 'SWEEP=daily\nCRUMB_AGE_MIN=60\n' > "$CFG/charon.conf"
[ "$(crumb_age_min)" = 60 ] \
  || fail "crumb_age_min ignored CRUMB_AGE_MIN from config: $(crumb_age_min)"
# Env still wins, for a one-off sweep by hand.
[ "$(CHARON_CRUMB_AGE_MIN=5 crumb_age_min)" = 5 ] \
  || fail "the environment did not override the config"
# And the built-in day applies with neither.
printf 'SWEEP=daily\n' > "$CFG/charon.conf"
[ "$(crumb_age_min)" = 1440 ] || fail "the built-in default is not 1440"

# IT REFUSES A NON-NUMERIC VALUE instead of coercing it. This is the sharp edge:
# any coercion that lands on 0 makes `find -mmin +0` match EVERYTHING, so a typo
# would delete the fresh temps that are live resume points.
for bad in abc '12m' '-5' '1 0' 0.5; do
  printf 'CRUMB_AGE_MIN=%s\n' "$bad" > "$CFG/charon.conf"
  crumb_age_min >/dev/null 2>&1 \
    && fail "crumb_age_min ACCEPTED '$bad'; a bad age gate deletes live resume
    points rather than litter, so it must refuse"
done
# An EMPTY value is indistinguishable from an absent key to the reader, so it
# falls back to the SAFE default rather than refusing -- and the thing that
# matters is which way it falls: 1440, never 0.
printf 'CRUMB_AGE_MIN=\n' > "$CFG/charon.conf"
[ "$(crumb_age_min)" = 1440 ] \
  || fail "an empty CRUMB_AGE_MIN did not fall back to the safe default;
  got '$(crumb_age_min)', and anything landing on 0 sweeps live resume points"
# ...and a refusal stops the sweep rather than sweeping with a guess.
printf 'CRUMB_AGE_MIN=oops\n' > "$CFG/charon.conf"
mkdir -p "$T/cache/D"
FRESH="$T/cache/D/.unison.fresh.aaa.unison.tmp"
printf 'x' > "$FRESH"
do_sweep >/dev/null 2>&1 \
  && fail "do_sweep proceeded with an invalid CRUMB_AGE_MIN"
[ -f "$FRESH" ] \
  || fail "do_sweep deleted a temp while refusing an invalid age gate"
# check calls that DRIFT, not litter: nothing would ever be swept, silently.
printf 'CRUMB_AGE_MIN=oops\n' > "$CFG/charon.conf"
_ck=$(check_crumbs 2>&1); _ckrc=$?
[ "$_ckrc" = 0 ] && fail "check_crumbs shrugged at an unusable CRUMB_AGE_MIN"
case $_ck in
  *CRUMB_AGE_MIN*) : ;;
  *) fail "check_crumbs did not name the bad setting: $_ck" ;;
esac

# The age is actually APPLIED, both sides of the boundary.
printf 'CRUMB_AGE_MIN=60\n' > "$CFG/charon.conf"
OLD="$T/cache/D/.unison.old.bbb.unison.tmp"
printf 'x' > "$OLD"; touch -d '3 hours ago' "$OLD"
[ "$(crumbs_in "$T/cache/D" 60 | wc -l)" = 1 ] \
  || fail "a 3h-old crumb was not matched by a 60m age gate"
[ "$(crumbs_in "$T/cache/D" 600 | wc -l)" = 0 ] \
  || fail "a 3h-old crumb WAS matched by a 600m age gate, so the gate does
  nothing and fresh resume points are at risk"

pass "the sweep is the user's call, in both directions, and the age gate holds"
