#!/bin/sh
# source-mount.t - the mount and the sync must resolve the SAME source.
#
# This is the property that makes it safe for an integrator to declare a
# source at all. Until it held, charon-mount read CHARON_REMOTE directly while
# charon-sync resolved a source, so a declared source would have moved the sync
# and left the mount behind: one fact in two places, free to drift.
. "$(dirname "$0")/lib.sh"
harness_init source-mount

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
export CHARON_REMOTE=testremote
CFG=$XDG_CONFIG_HOME/charon
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d"
mkdir -p "$T/testremote" "$T/elsewhere/tree" "$T/elsewhere/cache"
for s in unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
# systemctl RECORDS what it was asked to do. The mount unit is a template
# instanced by SOURCE now, so the enabled INSTANCE NAME is what proves the
# timed run resolves the declared source; that used to be a baked Environment
# line, which was a copy of sources.d free to go stale against it.
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/systemctl.log"
exit 0
EOF
chmod +x "$T/bin/systemctl"
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
# rclone must report BOTH remotes as configured, or ensure_rclone correctly
# refuses to install a unit for a remote that does not exist.
cat > "$T/bin/rclone" <<'EOF'
#!/bin/sh
case "$1" in
  listremotes) printf 'testremote:\notherremote:\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/rclone"

_mount() { PATH="$T/bin:$PATH" sh "$HERE/bin/charon" mount "$@" 2>&1; }

# --- with NO sources.d file, the implicit default must reproduce exactly what
# --- CHARON_REMOTE gave before: this change is a no-op for a single remote.
out=$(_mount status)
case "$out" in
  *"$T/testremote"*) : ;;
  *) fail "implicit default did not derive ~/\$CHARON_REMOTE (got: $out)" ;;
esac

# --- a DECLARED source must move the mount, not just the sync ---
cat > "$CFG/sources.d/default.conf" <<EOF
MOUNT=$T/elsewhere/tree
CACHE_ROOT=$T/elsewhere/cache
REMOTE=otherremote
EOF
out=$(_mount status)
case "$out" in
  *"$T/elsewhere/tree"*) : ;;
  *) fail "declared source did not move the MOUNT (got: $out)" ;;
esac
case "$out" in
  *otherremote*) : ;;
  *) fail "declared source did not move the remote NAME (got: $out)" ;;
esac

# --- and the sync must agree with it, from the same declaration ---
printf 'SUBTREE=Docs\n' > "$CFG/profiles.d/docs.conf"
PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync install >/dev/null 2>&1 \
  || fail "sync install errored against a declared source"
prf=$T/.unison/charon-docs.prf
grep -q "^root = $T/elsewhere/tree/Docs\$" "$prf" \
  || fail "sync did not resolve the SAME source the mount did"
grep -q "^root = $T/elsewhere/cache/Docs\$" "$prf" \
  || fail "sync did not take CACHE_ROOT from the declared source"

# --- the INSTANCE must name the source, so the timed run resolves it too ---
: > "$T/systemctl.log"
PATH="$T/bin:$PATH" sh "$HERE/bin/charon" mount install >/dev/null 2>&1 \
  || fail "mount install errored (did it demand privilege it does not need?)"
unit=$XDG_CONFIG_HOME/systemd/user/charon-mount@.service
grep -q '^ExecStart=.*charon source up %i$' "$unit" \
  || fail "the mount template does not bring its own instance's source up"
grep -q '^Environment=CHARON_SOURCE=' "$unit" \
  && fail "the template bakes a source name; %i must be the only carrier" || :
grep -q 'enable .*charon-mount@default\.service' "$T/systemctl.log" \
  || fail "install did not enable the instance for the DECLARED source"

# --- install must need NO privilege: no sudo on PATH at all ---
# charon-mount used to run `sudo true` up front, which made it unrunnable from
# any non-TTY context on a box where rclone was already present.
rm -f "$T/bin/sudo"
env PATH="$T/bin:/usr/bin:/bin" HOME="$T" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
  CHARON_REMOTE=testremote sh "$HERE/bin/charon" mount install >/dev/null 2>&1 \
  || fail "mount install needed privilege it should not have needed"

pass "mount and sync resolve one source; the instance names it; no sudo"
