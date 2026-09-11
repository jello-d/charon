#!/bin/sh
# skip.t - the SKIP contract. A pass that did NO WORK must be distinguishable
# from one that synced, at the exit status and in the log. This regressed once
# in the worst way: a detached archive rebuild reported EXIT=0 for both
# profiles in the second it started, which read as "rebuilt" and meant
# "skipped", and only the missing archive files gave it away. So: an offline
# remote exits EX_SKIP (75), not 0, and says why at the DEFAULT log level.
. "$(dirname "$0")/lib.sh"
harness_init skip

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
export CHARON_REMOTE=testremote          # -> ~/testremote + ~/.testremote

mkdir -p "$T/bin" "$T/.testremote/Docs" "$T/.cache" "$T/testremote/Docs"
mkdir -p "$XDG_CONFIG_HOME/charon/profiles.d"
printf 'SUBTREE=Docs\n' > "$XDG_CONFIG_HOME/charon/profiles.d/docs.conf"

# stubs: unison + mountpoint succeed, so the ONLY thing deciding the outcome is
# whether the remote answers. systemd-inhibit is deliberately absent, which
# exercises the degrade-and-continue path too.
for s in systemctl unison mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done

_rclone() {   # <about-exit-code>
  printf '#!/bin/sh\ncase "$1" in about) exit %s ;; esac\nexit 0\n' "$1" \
    > "$T/bin/rclone"
  chmod +x "$T/bin/rclone"
}

# --- OFFLINE: the remote does not answer -> SKIP, not success ---
_rclone 1
out=$(PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync run docs 2>&1); rc=$?
[ "$rc" = 75 ] || fail "offline pass exited $rc, expected 75 (EX_SKIP)"
printf '%s\n' "$out" | grep -qi 'offline' \
  || fail "offline skip did not say WHY at the default log level"
printf '%s\n' "$out" | grep -q 'SKIPPED' \
  || fail "offline skip did not announce itself as SKIPPED"

# --- ONLINE: the remote answers -> a real pass -> success ---
_rclone 0
out=$(PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync run docs 2>&1); rc=$?
[ "$rc" = 0 ] || fail "online pass exited $rc, expected 0 (got: $out)"
printf '%s\n' "$out" | grep -q 'SKIPPED' \
  && fail "a real pass reported itself as SKIPPED" || :

# --- the generated unit must tell systemd that 75 is not a failure, or an
# --- offline laptop accumulates failed units for an expected condition.
for s in sudo systemd-run dpkg; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
PATH="$T/bin:$PATH" sh "$HERE/bin/charon" sync install >/dev/null 2>&1 \
  || fail "sync install errored"
grep -q '^SuccessExitStatus=75$' \
  "$XDG_CONFIG_HOME/systemd/user/charon-sync@.service" \
  || fail "unit does not mark the skip status a systemd success"

pass "skip exits 75 and says why; a real pass exits 0"
