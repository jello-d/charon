#!/bin/sh
# verdict.t - `charon check` says whether an APPLY WOULD HELP, not merely
# whether something is wrong.
#
# THE GAP THIS CLOSES, measured on a live fleet 2026-09-24. An integrator reads
# a non-zero check as drift, schedules a repair, runs it, finds the check still
# failing, and reports "bad state or a bug". tackup's own summary code concedes
# the point in a comment ("a check cannot tell the two apart") and works
# around it by calling everything "findings". That cost three full provision
# passes re-installing units and re-seeding a wallpaper for a fault no
# re-provision could touch.
#
# charon CAN tell them apart, so it must say which:
#
#   0  clean
#   1  DRIFT  an artifact differs from what this version writes, a unit is not
#             enabled, a path charon owns is missing, and re-provision fixes it
#   2  FAULT  the install is correct and something is failing, or the config
#             itself is wrong, and it needs time or a human
#
# DRIFT BEATS FAULT when both are present, and that ordering is what makes it
# safe for an integrator to skip the repair on a bare fault: if anything
# repairable is wrong the caller repairs first, and a surviving fault is
# reported by the next check.
. "$(dirname "$0")/harness_lib"
harness_init verdict

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_TRAITS_DIR=$T/st
export CHARON_STATE=$T/state
export UNISON_DIR=$T/uni
export XDG_CONFIG_HOME=$T/xdg
CFG=$T/cfg
SD=$T/xdg/systemd/user
WANTS=$SD/timers.target.wants
mkdir -p "$CFG/profiles.d" "$CFG/sources.d" "$T/st" "$T/uni" "$T/.cache" \
         "$T/bin" "$T/state" "$SD" "$WANTS" "$T/src/D" "$T/cache/D"

# ----------------------------------------------------------------- part 1 ----
# THE MERGE RULE, on its own. It is the contract's load-bearing half and it has
# exactly one definition, shared by both impls and the dispatcher.
CHARON_LIB_ONLY=1 . "$HERE/libexec/common_lib"

[ "$EX_DRIFT" = 1 ] || fail "EX_DRIFT is $EX_DRIFT, not 1"
[ "$EX_FAULT" = 2 ] || fail "EX_FAULT is $EX_FAULT, not 2"

_m() { merge_verdict "$1" "$2"; printf '%s' "$?"; }
[ "$(_m 0 0)" = 0 ] || fail "clean + clean is not clean"
[ "$(_m 1 0)" = 1 ] || fail "drift + clean is not drift"
[ "$(_m 0 1)" = 1 ] || fail "clean + drift is not drift"
[ "$(_m 2 0)" = 2 ] || fail "fault + clean is not fault"
[ "$(_m 0 2)" = 2 ] || fail "clean + fault is not fault"
[ "$(_m 2 2)" = 2 ] || fail "fault + fault is not fault"
# THE ORDERING, both ways round. It used to depend on which half ran last,
# because the dispatcher's `|| _rc=$?` simply OVERWROTE.
[ "$(_m 1 2)" = 1 ] \
  || fail "drift + fault gave $(_m 1 2); drift must win so the caller repairs
  what it can before concluding anything about the fault"
[ "$(_m 2 1)" = 1 ] \
  || fail "fault + drift gave $(_m 2 1), so the answer depends on the ORDER the
  two halves ran in -- which is the bug this rule replaced"
# A verdict charon does not define is not flattened into one: an unexplained
# failure is at least worth looking at, so it reports drift.
[ "$(_m 0 3)" = 1 ] || fail "an undefined verdict was treated as clean"

# ----------------------------------------------------------------- part 2 ----
# A FINDING CANNOT BE REPORTED WITHOUT CLASSIFYING ITSELF, and a check that
# fails without doing so is a BUG charon says out loud rather than silently
# downgrading to clean.
CHECK_DRIFT=; CHECK_FAULT=
check_verdict 0 || fail "a clean check did not report clean"
CHECK_DRIFT=; CHECK_FAULT=
_out=$(check_verdict 1); _rc=$?
[ "$_rc" = "$EX_DRIFT" ] \
  || fail "an unclassified failure returned $_rc; it must not become clean"
case $_out in
  *BUG*) : ;;
  *) fail "an unclassified failure was silent about being a bug: $_out" ;;
esac
# The helpers classify, and print a marker a reader can tell apart.
#
# CAPTURED TO A FILE, NOT WITH $( ). These set a shell variable, and a command
# substitution runs in a SUBSHELL where the assignment cannot escape, so the
# first version of this asserted the flag was unset and "caught" a bug that was
# entirely its own. The same trap once made a warn-once guard look broken here.
CHECK_DRIFT=; CHECK_FAULT=
fail_drift "a unit is stale" >"$T/d"
[ -n "$CHECK_DRIFT" ] || fail "fail_drift did not set the drift class"
[ -z "$CHECK_FAULT" ] || fail "fail_drift set the FAULT class too"
grep -q '\[FAIL\]' "$T/d" || fail "fail_drift marker wrong: $(cat "$T/d")"
CHECK_DRIFT=; CHECK_FAULT=
fail_fault "the last run failed" >"$T/f"
[ -n "$CHECK_FAULT" ] || fail "fail_fault did not set the fault class"
[ -z "$CHECK_DRIFT" ] || fail "fail_fault set the DRIFT class too"
grep -q '\[FAULT\]' "$T/f" || fail "fail_fault marker wrong: $(cat "$T/f")"

# ----------------------------------------------------------------- part 3 ----
# END TO END, through the real `charon check`, for each verdict in turn.
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
# A systemctl that MODELS enablement, so "not enabled" can actually be produced
# and is not just assumed. A stub that exits 0 for everything answers "enabled"
# to every question and makes each assertion below unfalsifiable.
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
SD=$SD; W=$WANTS
a=
for x in "\$@"; do
  case "\$x" in --user|--now|-q|--quiet|--no-legend|--all) ;; *) a="\$a \$x";;
  esac
done
# shellcheck disable=SC2086
set -- \$a
case "\${1:-}" in
  enable)  shift; for u in "\$@"; do [ -f "\$SD/\$u" ] || exit 1
             ln -sfn "\$SD/\$u" "\$W/\$u"; done ;;
  disable) shift; for u in "\$@"; do rm -f "\$W/\$u"; done ;;
  is-enabled|is-active) { [ -L "\$W/\$2" ] && [ -f "\$SD/\$2" ]; } || exit 4 ;;
  list-unit-files) printf 'charon-sync@.service enabled\n' ;;
  # The last-run outcome is READ FROM FILES the test writes, so a genuinely
  # FAILED run can be simulated. A stub that always answers "never ran" cannot
  # produce the original 2026-09-24 symptom at all, and a classification nothing
  # can exercise is a classification nothing pins.
  show) case "\$*" in
          *ExecMainStartTimestamp*) cat $T/o.ts  2>/dev/null || echo "" ;;
          *ExecMainStatus*)         cat $T/o.st  2>/dev/null || echo "" ;;
          *Result*)                 cat $T/o.res 2>/dev/null || echo "" ;;
        esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/systemctl"
for s in systemd-run mountpoint unison; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"; done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

_c() { PATH="$T/bin:/usr/bin:/bin" sh "$HERE/libexec/charon-sync" "$@"; }

_c install >/dev/null 2>&1 || fail "install failed (verdict setup)"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = 0 ] \
  || fail "a FRESH install does not check CLEAN ($_v). Every assertion below
  measures a deviation from this baseline, so a red baseline makes the whole
  file theatre: $(cat "$T/v")"

# --- DRIFT: an artifact differs from what this version writes ----------------
printf '\n# hand-edited\n' >> "$UNISON_DIR/charon-docs.prf"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_DRIFT" ] \
  || fail "a hand-edited prf gave verdict $_v, expected DRIFT ($EX_DRIFT):
  $(cat "$T/v")"
grep -q '\[FAIL\]' "$T/v" || fail "drift was not marked [FAIL]: $(cat "$T/v")"
grep -q '\[FAULT\]' "$T/v" && fail "drift was marked as a FAULT"
_c install >/dev/null 2>&1
_c check >/dev/null 2>&1 || fail "re-provisioning did not clear the drift, which
  is the whole claim the DRIFT verdict makes"

# --- FAULT: the install is correct and something is failing ------------------
# A recorded failing path is the cheapest honest fault: the units are all
# correct, and no amount of re-provisioning makes the path sync.
mkdir -p "$T/state/failed"
printf 'SINCE=1\nLAST=2\nSTREAK=5\nRC=2\nFAILED=stuck one.psp\n' \
  > "$T/state/failed/docs"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_FAULT" ] \
  || fail "a stuck path gave verdict $_v, expected FAULT ($EX_FAULT):
  $(cat "$T/v")"
grep -q '\[FAULT\]' "$T/v" || fail "the fault was not marked [FAULT]"
# AND RE-PROVISIONING MUST NOT CLEAR IT. That is not a limitation, it is the
# assertion: if an apply fixed this, calling it a fault would be a lie.
_c install >/dev/null 2>&1
_c check >/dev/null 2>&1 \
  && fail "an apply cleared what charon called a FAULT, so the classification
  is wrong: it was drift all along"

# --- BOTH: drift wins, so the caller repairs first --------------------------
printf '\n# hand-edited again\n' >> "$UNISON_DIR/charon-docs.prf"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_DRIFT" ] \
  || fail "with BOTH a stale artifact and a stuck path the verdict was $_v; it
  must be DRIFT so the caller repairs what it can: $(cat "$T/v")"
grep -q '\[FAIL\]'  "$T/v" || fail "the drift half went unreported"
grep -q '\[FAULT\]' "$T/v" || fail "the fault half went unreported"
# After the repair, what is left is the fault alone.
_c install >/dev/null 2>&1
_c check >/dev/null 2>&1; _v=$?
[ "$_v" = "$EX_FAULT" ] \
  || fail "after repairing the drift the residual verdict was $_v, expected
  FAULT: an integrator needs that to distinguish 'apply did not fix it' from
  'there was nothing apply could do'"
rm -f "$T/state/failed/docs"
_c check >/dev/null 2>&1 || fail "removing the fault did not return to clean"

# --- CONFIG ERROR is a fault too: no apply fixes a wrong declaration --------
printf 'CRUMB_AGE_MIN=not-a-number\n' > "$CFG/charon.conf"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_FAULT" ] \
  || fail "an unusable CRUMB_AGE_MIN gave verdict $_v, expected FAULT: an apply
  cannot correct the user's own config file"
rm -f "$CFG/charon.conf"

# --- A FAILED LAST RUN is the original symptom, and is a FAULT --------------
# This is the finding that started all of it: `charon-sync@media.service last
# run: exit-code`, reported as drift, repaired three times, never fixed.
printf 'Fri 2026-09-25 12:00:00 EDT\n' > "$T/o.ts"
printf 'failed\n' > "$T/o.res"
printf '2\n' > "$T/o.st"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_FAULT" ] \
  || fail "a FAILED last run gave verdict $_v, expected FAULT ($EX_FAULT). This
  is the exact finding that cost three provision passes: $(cat "$T/v")"
grep -q '\[FAULT\].*last run' "$T/v" \
  || fail "the failed last run was not marked [FAULT]: $(cat "$T/v")"
_c install >/dev/null 2>&1
_c check >/dev/null 2>&1 \
  && fail "an apply cleared a FAILED LAST RUN, which it cannot do: the
  classification would then be wrong"
rm -f "$T/o.ts" "$T/o.res" "$T/o.st"
_c check >/dev/null 2>&1 || fail "clearing the outcome did not return to clean"

# --- A DRIFTED UNIT, through check_generated ---------------------------------
# The prf case above has its own message; this one goes through the SHARED
# artifact differ, which every generated unit and timer uses. Without it, a
# mutation flipping that one differ to FAULT survived.
printf '\n# hand-edited\n' >> "$SD/charon-sync-docs.timer"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_DRIFT" ] \
  || fail "a hand-edited TIMER gave verdict $_v, expected DRIFT ($EX_DRIFT):
  $(cat "$T/v")"
grep -q '\[FAULT\]' "$T/v" \
  && fail "a stale generated artifact was classified as a FAULT; re-provisioning
  is exactly what fixes it"
_c install >/dev/null 2>&1
_c check >/dev/null 2>&1 || fail "the apply did not clear the timer drift"

# --- THE TWO ROOTS ARE CLASSIFIED DIFFERENTLY, because different people own
# them. install CREATES the cache root, so a missing one is drift. It
# deliberately does NOT create the MOUNT: for PROVIDER=none that is someone
# else's tree, and an empty directory where a missing mount belongs is how a
# dead mount gets mistaken for a live one.
rm -rf "$T/cache"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_DRIFT" ] \
  || fail "a missing CACHE_ROOT gave verdict $_v, expected DRIFT ($EX_DRIFT):
  install creates it, so a re-provision is exactly the remedy: $(cat "$T/v")"
_c install >/dev/null 2>&1
_c check >/dev/null 2>&1 \
  || fail "the apply did not recreate the cache root it claims to own"

rm -rf "$T/src"
_c check >"$T/v" 2>&1; _v=$?
[ "$_v" = "$EX_FAULT" ] \
  || fail "a missing MOUNT gave verdict $_v, expected FAULT ($EX_FAULT): charon
  will not create someone else's tree, so no apply fixes it: $(cat "$T/v")"
_c install >/dev/null 2>&1
_c check >/dev/null 2>&1 \
  && fail "an apply CREATED the missing mount root; that is the dead-mount
  hazard charon exists to avoid, not a repair"
mkdir -p "$T/src/D"
_c check >/dev/null 2>&1 || fail "restoring the mount did not return to clean"

# --- EVERY VERDICT IS STILL NON-ZERO, so a caller that only tests success is
# unaffected. That is what makes this change safe to ship to existing
# integrators before they know about it.
[ "$EX_DRIFT" != 0 ] && [ "$EX_FAULT" != 0 ] \
  || fail "a non-clean verdict is zero; every existing caller tests non-zero"

pass "check says whether an apply would help, and drift beats fault"
