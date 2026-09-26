#!/bin/sh
# verbs.t - the flattened verb surface, AND the promise that every older
# spelling still works.
#
# The compatibility half is the load-bearing one. A generated unit outlives the
# version that wrote it: a box can be carrying `ExecStart=charon sync run media`
# from a previous install when a renamed charon lands under it. If the old verb
# were gone, the sync would die at the rename rather than at anything real.
# So the aliases are a correctness requirement, not politeness.
. "$(dirname "$0")/lib.sh"
harness_init verbs

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
export CHARON_REMOTE=testremote
CFG=$XDG_CONFIG_HOME/charon
mkdir -p "$T/bin" "$CFG/profiles.d" "$T/testremote/Docs" \
         "$T/.testremote/Docs"
for s in systemctl unison mountpoint systemd-run sudo; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\ncase "$1" in listremotes) echo testremote: ;; esac\n' \
  > "$T/bin/rclone"
printf 'exit 0\n' >> "$T/bin/rclone"; chmod +x "$T/bin/rclone"
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
printf 'SUBTREE=Docs\n' > "$CFG/profiles.d/docs.conf"

_c() { PATH="$T/bin:$PATH" sh "$HERE/bin/charon" "$@"; }

# --- the flattened surface ---
_c install >/dev/null 2>&1 || fail "charon install (both halves) errored"
[ -f "$T/.unison/charon-docs.prf" ] || fail "install did not generate the prf"
[ -f "$XDG_CONFIG_HOME/systemd/user/charon-mount@.service" ] \
  || fail "charon install did not install the MOUNT half too"

# status is a HUMAN view, distinct from check's machine verdict: it must never
# fail, never probe (a probe writes), and never mutate anything.
_c status >/dev/null 2>&1 || fail "charon status errored"
out=$(_c status 2>&1)
printf '%s\n' "$out" | grep -q "source 'default'" || fail "status: no source"
printf '%s\n' "$out" | grep -q "profile 'docs'"   || fail "status: no profile"
printf '%s\n' "$out" | grep -qi 'last run'        || fail "status: no outcome"
printf '%s\n' "$out" | grep -qi 'policy'          || fail "status: no policy"
printf '%s\n' "$out" | grep -qi 'traits'          || fail "status: no traits"
# it must report a BROKEN source rather than erroring on it
_snap=$(cat "$T/.local/state/charon/traits/default" 2>/dev/null || :)
rm -f "$T/.local/state/charon/traits/default"
_c status >/dev/null 2>&1 || fail "status errored on a source with no traits"
_c status 2>&1 | grep -qi 'traits: NONE' \
  || fail "status did not flag the missing traits"
printf '%s' "$_snap" > "$T/.local/state/charon/traits/default"
# and it must not have written anything into the source while looking
[ -e "$T/testremote/.charon-probe" ] && fail "status PROBED; it must not" || :
_c source list | grep -qx default || fail "charon source list"
_c sync docs >/dev/null 2>&1 || fail "charon sync <profile> errored"

# --- every older spelling still works ---
_c sync run docs >/dev/null 2>&1 || fail "legacy 'sync run <profile>' broke"
_c sync run      >/dev/null 2>&1 || fail "legacy 'sync run' (all) broke"
_c sync config   >/dev/null 2>&1 || fail "legacy 'sync config' broke"
_c mount status  >/dev/null 2>&1 || fail "legacy 'mount status' broke"
_c sync install  >/dev/null 2>&1 || fail "legacy 'sync install' broke"
_c mount install >/dev/null 2>&1 || fail "legacy 'mount install' broke"

# A profile is NOT shadowed by the legacy mode names: `charon sync docs` must
# reconcile the docs profile, not be mistaken for a mode.
_c sync docs >/dev/null 2>&1 || fail "a profile name was swallowed as a mode"

# --- the generated units use the NEW spelling ---
svc=$XDG_CONFIG_HOME/systemd/user/charon-sync@.service
grep -q '^ExecStart=.*/charon sync %i$' "$svc" \
  || fail "the sync unit does not use the flattened verb"
unit=$XDG_CONFIG_HOME/systemd/user/charon-mount@.service
grep -q '^ExecStart=.*/charon source up %i$' "$unit" \
  || fail "the mount template does not bring its instance's SOURCE up"

# ...but a unit carrying the OLD spelling must still run, which is the whole
# point of the aliases. Simulate a stale unit's ExecStart directly.
_c sync run docs >/dev/null 2>&1 \
  || fail "a stale unit's command line would fail against this version"
_c mount run --help >/dev/null 2>&1 || :

# --- the daily sweep backstop is installed, and runs the flattened verb ---
# It is a generated artifact like any other, so it must be WRITTEN by install
# and REMOVED by uninstall. An unenabled sweep timer means orphaned Unison
# temps accumulate on the remote with nothing ever collecting them, which is
# silent by nature: nothing breaks, the litter just grows.
swp=$XDG_CONFIG_HOME/systemd/user/charon-sweep.service
swt=$XDG_CONFIG_HOME/systemd/user/charon-sweep.timer
[ -f "$swp" ] || fail "install wrote no charon-sweep.service"
[ -f "$swt" ] || fail "install wrote no charon-sweep.timer"
grep -q '^ExecStart=.*/charon sweep$' "$swp" \
  || fail "the sweep unit does not run the flattened 'charon sweep' verb"
# 75 is charon's SKIPPED, which a sweep returns when a pass holds the lock. If
# systemd treated that as a failure, a box that happens to be mid-pass at the
# sweep hour would carry a failed unit forever for doing the right thing.
grep -q '^SuccessExitStatus=75$' "$swp" \
  || fail "the sweep unit does not treat charon's SKIPPED (75) as success"
# Persistent, unlike the sync timers: a missed sync is caught minutes later by
# the next interval, but a missed DAILY sweep would wait another whole day, and
# a laptop asleep at the sweep hour is the normal case.
grep -q '^Persistent=true$' "$swt" \
  || fail "the daily sweep timer is not Persistent; a box that was off at the
  sweep hour would skip a whole day"

# --- uninstall removes the machinery and NOTHING else ---
printf 'data\n' > "$T/.testremote/Docs/keep.txt"
_c uninstall >/dev/null 2>&1 || fail "charon uninstall errored"
[ -e "$swp" ] && fail "uninstall left charon-sweep.service" || :
[ -e "$swt" ] && fail "uninstall left charon-sweep.timer" || :
[ -e "$XDG_CONFIG_HOME/systemd/user/charon-sync@.service" ] \
  && fail "uninstall left the service template" || :
[ -e "$T/.unison/charon-docs.prf" ] && fail "uninstall left the prf" || :
[ -f "$T/.testremote/Docs/keep.txt" ] \
  || fail "uninstall touched the CACHE; it must never remove data"
[ -f "$CFG/profiles.d/docs.conf" ] \
  || fail "uninstall removed the user's config; it must not"

pass "flattened verbs, every legacy spelling, and a data-safe uninstall"
