#!/bin/sh
# profiles.t - the config-driven engine: a profiles.d/<name>.conf drives the
# generated unison profile, the systemd timer (with its cadence), the service
# template's baked config -- all from config, with no baked
# Media/Documents. Runs `charon-sync install` against stubs (no real rclone/
# unison/systemctl), everything confined to a scratch HOME.
. "$(dirname "$0")/lib.sh"
harness_init profiles

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
export CHARON_REMOTE=testremote        # -> ~/testremote + ~/.testremote
export CHARON_NOTIFY=my-notifier        # should be baked into the service unit

# stubs: install must not touch the real system. dpkg reports unison present
# (so no apt), the rest just succeed.
mkdir -p "$T/bin"
for s in sudo systemctl systemd-run rclone unison mountpoint my-notifier; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
# sudo just runs the rest (so `sudo true` etc. work)
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"

# a profile using the LEGACY SUBTREE= shorthand, which must keep working: it
# means "the implicit default source", so an existing install needs no edits.
# the source tree must EXIST: traits are measured, and you cannot measure
# a tree that is not there.
mkdir -p "$T/testremote/Docs" "$T/.testremote"
mkdir -p "$XDG_CONFIG_HOME/charon/profiles.d"
cat > "$XDG_CONFIG_HOME/charon/profiles.d/docs.conf" <<'EOF'
SUBTREE=Docs
INTERVAL=15m
BOOT=3m
JITTER=1m
SEED_FULL_ORDER=5
EOF

PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync install >/dev/null 2>&1 \
  || fail "charon sync install errored"

# 1) the unison profile: roots derived from CHARON_REMOTE + SUBTREE
prf=$T/.unison/charon-docs.prf
[ -f "$prf" ] || fail "unison profile not generated"
grep -q "^root = $T/testremote/Docs$" "$prf" || fail "prf mount root wrong"
grep -q "^root = $T/.testremote/Docs$" "$prf" || fail "prf cache root wrong"
grep -q "^prefer = $T/testremote/Docs$" "$prf" || fail "prf prefer (canonical)"

# 2) the timer: cadence from the profile, instanced service name
tmr=$XDG_CONFIG_HOME/systemd/user/charon-sync-docs.timer
[ -f "$tmr" ] || fail "timer not generated"
grep -q '^OnUnitActiveSec=15m$' "$tmr" || fail "timer INTERVAL not applied"
grep -q '^OnBootSec=3m$'        "$tmr" || fail "timer BOOT not applied"
grep -q '^RandomizedDelaySec=1m$' "$tmr" || fail "timer JITTER not applied"
grep -q '^Unit=charon-sync@docs.service$' "$tmr" || fail "timer Unit wrong"

# 3) the service template: baked remote + notify seam
svc=$XDG_CONFIG_HOME/systemd/user/charon-sync@.service
[ -f "$svc" ] || fail "service template not generated"
grep -q '^Environment=CHARON_REMOTE=testremote$' "$svc" \
  || fail "service did not bake CHARON_REMOTE"
# The notify seam must be baked as an ABSOLUTE path, not the bare name it was
# configured with: a --user unit's PATH has no ~/bin or ~/.local/bin, so a bare
# name is unresolvable exactly where it has to run, and faults reach nobody.
grep -q "^Environment=CHARON_NOTIFY=$T/bin/my-notifier\$" "$svc" \
  || fail "notify seam not resolved to an absolute path in the unit"

# 4) charon must lay NO working links: that is the integrator's layout job, and
# the LINK= key is retired. A stray link here means the key came back.
[ -e "$T/work-docs" ] \
  && fail "charon laid a working link; the LINK= key is retired" || :

# 5) check must SEE a hand-patched prf. install and check share one renderer,
# so a live prf that no longer matches the template this version would generate
# is reported as drift rather than passing unnoticed (three interim hand
# patches once rode on two boxes' prfs and units at the same time, invisibly).
PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync check >"$T/chk1.out" 2>&1 || :
grep -q '\[OK\].*charon-docs.prf matches' "$T/chk1.out" \
  || fail "check did not verify the generated prf against the template"
printf '\n# hand patch\nfastcheck = false\n' >> "$prf"
PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync check >"$T/chk2.out" 2>&1
[ "$?" = 0 ] && fail "check exited 0 on a hand-patched prf" || :
grep -q '\[FAIL\].*charon-docs.prf DIFFERS' "$T/chk2.out" \
  || fail "check did not report the hand-patched prf as drift"

# 6) NO profile == no generation (a bare config dir is inert, not an error)
rm -f "$XDG_CONFIG_HOME/charon/profiles.d/docs.conf"
PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync config >"$T/cfg.out" 2>&1 \
  || fail "config errored with no profiles"
grep -qi 'none' "$T/cfg.out" || fail "config did not note the empty profile set"

pass "profile config -> prf + timer + service"
