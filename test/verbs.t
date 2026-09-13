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
[ -f "$XDG_CONFIG_HOME/systemd/user/charon-mount.service" ] \
  || fail "charon install did not install the MOUNT half too"

_c status >/dev/null 2>&1 || fail "charon status errored"
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
unit=$XDG_CONFIG_HOME/systemd/user/charon-mount.service
grep -q '^ExecStart=.*/charon source up default$' "$unit" \
  || fail "the mount unit does not bring the SOURCE up"

# ...but a unit carrying the OLD spelling must still run, which is the whole
# point of the aliases. Simulate a stale unit's ExecStart directly.
_c sync run docs >/dev/null 2>&1 \
  || fail "a stale unit's command line would fail against this version"
_c mount run --help >/dev/null 2>&1 || :

# --- uninstall removes the machinery and NOTHING else ---
printf 'data\n' > "$T/.testremote/Docs/keep.txt"
_c uninstall >/dev/null 2>&1 || fail "charon uninstall errored"
[ -e "$XDG_CONFIG_HOME/systemd/user/charon-sync@.service" ] \
  && fail "uninstall left the service template" || :
[ -e "$T/.unison/charon-docs.prf" ] && fail "uninstall left the prf" || :
[ -f "$T/.testremote/Docs/keep.txt" ] \
  || fail "uninstall touched the CACHE; it must never remove data"
[ -f "$CFG/profiles.d/docs.conf" ] \
  || fail "uninstall removed the user's config; it must not"

pass "flattened verbs, every legacy spelling, and a data-safe uninstall"
