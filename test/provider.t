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
for s in unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
# systemctl must answer `list-unit-files` from the unit DIR, not exit 0 and
# print nothing: check asks whether the sync template is REGISTERED, and a
# silent stub makes that FAIL for a reason that has nothing to do with charon.
# That noise is why nothing here ever asserted check's exit status, which in
# turn hid a real defect (a BYO-only install could never pass).
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
SD=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
case " $* " in
  *" list-unit-files "*)
    for f in "$SD"/*.service "$SD"/*.timer; do
      [ -e "$f" ] || continue
      printf '%s enabled\n' "${f##*/}"
    done 2>/dev/null ;;
esac
exit 0
STUB
chmod +x "$T/bin/systemctl"

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

# --- config catastrophes must be REFUSED, not generated ---
# charon happily accepted MOUNT == CACHE_ROOT and even wrote a profile with the
# SAME ROOT TWICE: unison reconciling a tree against itself. A cache nested
# inside the tree it caches is the same class, syncing its own contents
# forever. Neither is a misconfiguration to warn about; both destroy data.
cp "$CFG/sources.d/nas.conf" "$T/nas.conf.bak"
printf 'PROVIDER=none\nMOUNT=%s/nas\nCACHE_ROOT=%s/nas\n' "$T" "$T" \
  > "$CFG/sources.d/nas.conf"
_c check 2>&1 | grep -qi 'same tree or nested' \
  || fail "MOUNT == CACHE_ROOT was not reported"
_c install >/dev/null 2>&1 && fail "install accepted an overlapping source" || :
printf 'PROVIDER=none\nMOUNT=%s/nas\nCACHE_ROOT=%s/nas/inner\n' "$T" "$T" \
  > "$CFG/sources.d/nas.conf"
_c check 2>&1 | grep -qi 'same tree or nested' \
  || fail "a cache nested inside its source was not reported"
cp "$T/nas.conf.bak" "$CFG/sources.d/nas.conf"

# two profiles on ONE pair of trees race, each with its own archive
cp "$CFG/profiles.d/docs.conf" "$CFG/profiles.d/dup.conf"
_c check 2>&1 | grep -qi 'more than one profile reconciles' \
  || fail "a duplicated (source, subtree) target was not reported"
rm -f "$CFG/profiles.d/dup.conf"
_c check 2>&1 | grep -qi 'config is coherent' \
  || fail "a clean config was not reported as coherent"

# --- THE VERDICT ITSELF: a BYO-only install must be able to PASS check ---
# Nothing here asserted this, and that is exactly what hid a real defect: every
# other `_c check` in this file greps the OUTPUT or swallows the status with
# `|| :`, so charon could fail forever and this test would not care. It did:
# install deliberately writes no mount template when no source is rclone-backed,
# while check demanded one anyway, so a PROVIDER=none-only box exited 0 from
# install and 1 from check with nothing a user could do. An integrator
# delegating its verdict to `charon check` -- the contract -- would show
# permanent drift on a feature charon advertises.
out=$(_c check 2>&1); rc=$?
[ "$rc" = 0 ] || fail "a healthy BYO-only install cannot PASS check (rc=$rc):
$out"
printf '%s\n' "$out" | grep -qi 'mounts nothing here' \
  || fail "check did not say plainly that there is nothing to mount ($out)"

# --- a SECOND rclone source is a supported configuration, not a fault ---
# This block used to assert the opposite: charon had one mount unit with a
# source baked in, so a second rclone-backed source could never be mounted and
# check FAILED on sight of one. The unit is a template instanced by source now,
# so the limit is gone. Keep the assertion inverted rather than deleting it, or
# nothing here would notice the limit creeping back.
# The deep wiring (one instance each, per-profile ordering) is multi-remote.t;
# this only pins that the provider seam ACCEPTS the configuration.
for _n in one two; do
  cat > "$CFG/sources.d/$_n.conf" <<EOF
PROVIDER=rclone
REMOTE=remote-$_n
MOUNT=$T/$_n
CACHE_ROOT=$T/${_n}cache
EOF
done
out=$(_c check 2>&1) || :
printf '%s\n' "$out" | grep -qi 'ONE mount unit' \
  && fail "the retired one-remote limit is back ($out)" || :
rm -f "$CFG/sources.d/one.conf" "$CFG/sources.d/two.conf"
_c check >/dev/null 2>&1 || :   # back to one source

# --- no systemd must be LOUD, not silently successful ---
# charon schedules through systemd --user. Without it, install still writes the
# unit files (they are just text) and used to exit 0 having scheduled nothing,
# which is silent success on an error path.
# Removing the stub is NOT enough: the real systemctl is still on /usr/bin, so
# `command -v` finds it and the no-systemd path never runs. Build a PATH that
# genuinely lacks it, by mirroring the system bins minus the two.
rm -f "$T/bin/systemctl" "$T/bin/systemd-run"   # the stubs, first on PATH
# path_without does the mirroring AND asserts its own honesty; this block was
# hand-rolled here first, and inhibitor.t then rebuilt it badly because it was
# not shared.
_nd=$(path_without systemctl systemd-run) || exit 1
_nosd() { PATH="$T/bin:$_nd" sh "$HERE/bin/charon" "$@"; }
out=$(_nosd install 2>&1) || :
printf '%s\n' "$out" | grep -qi 'NOTHING IS SCHEDULED' \
  || fail "install said nothing about systemd being absent ($out)"
_nosd check >/dev/null 2>&1 \
  && fail "check passed with no scheduler at all" || :
_nosd check 2>&1 | grep -qi 'systemctl not found' \
  || fail "check did not name the missing scheduler"

pass "PROVIDER=none: gates, syncs, seeds and refuses, with no rclone"
