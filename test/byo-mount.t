#!/bin/sh
# byo-mount.t - PROVIDER=none against a REAL MOUNT that charon does not own:
# the fstab / autofs / NFS case, as opposed to a plain directory.
#
# provider.t covers a plain directory, and that is NOT the same test. The two
# differ at exactly the place that matters -- `mountpoint -q` -- and the
# dangerous real-world failure is one a directory cannot simulate at all: the
# mount GOING AWAY underneath charon, leaving an empty directory where a full
# tree was. Under a two-way sync that reads as "everything was deleted", and
# propagating it is how you lose the far side. This test unmounts for real.
#
# The mount is made with rclone's on-the-fly :local: remote, which needs no
# root and no configured remote; charon is told PROVIDER=none, so as far as it
# is concerned something else entirely owns the tree.
. "$(dirname "$0")/lib.sh"
harness_init byo-mount

command -v rclone >/dev/null 2>&1 || skip "rclone not installed"
command -v fusermount3 >/dev/null 2>&1 \
  || command -v fusermount >/dev/null 2>&1 \
  || skip "no fusermount; cannot make a user-space mount"

MNT=$T/mnt
_umount() {
  fusermount3 -u "$MNT" 2>/dev/null || fusermount -u "$MNT" 2>/dev/null || :
}
# harness_init's trap removes $T; make sure we unmount first or the rmdir of a
# live mountpoint fails and leaves a stray FUSE process behind.
trap '_umount; rm -rf "$T"' EXIT INT TERM

export HOME=$T
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/real/Docs" \
         "$T/cache/Docs" "$MNT"
echo content > "$T/real/Docs/a.txt"

for s in unison mountpoint systemctl systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
# a REAL mountpoint check is the whole point here, so the stub must not shadow
# the real tool.
rm -f "$T/bin/mountpoint"

rclone mount :local:"$T/real" "$MNT" --daemon --vfs-cache-mode off 2>/dev/null \
  || skip "could not create a user-space mount"
_n=0
while [ $_n -lt 30 ]; do
  mountpoint -q "$MNT" && break
  _n=$((_n + 1)); sleep 0.2
done
mountpoint -q "$MNT" || skip "mount did not come up"

cat > "$CFG/sources.d/nas.conf" <<EOF
PROVIDER=none
MOUNT=$MNT
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=nas:Docs\n' > "$CFG/profiles.d/docs.conf"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg sh "$HERE/bin/charon" "$@"
}

# --- a real mount charon did not create is a valid source ---
_c source status nas >/dev/null 2>&1 || fail "a REAL mount was reported down"
_c source health nas >/dev/null 2>&1 || fail "a REAL mount was reported offline"

# --- traits are measured against the actual mount, not guessed ---
_c install >/dev/null 2>&1 || fail "install failed against a real BYO mount"
grep -q '^FSTYPE=fuse' "$T/st/nas" \
  || fail "traits did not see a FUSE filesystem ($(cat "$T/st/nas"))"
grep -q "^root = $MNT/Docs\$" "$T/uni/charon-docs.prf" \
  || fail "prf did not use the mounted path"

# --- THE REAL FAILURE MODE: the mount goes away underneath charon ---
# An fstab/NFS mount that drops leaves an EMPTY DIRECTORY where the tree was.
# A plain-directory test cannot produce this at all.
echo keep > "$T/cache/Docs/keep.txt"     # the cache holds data...
_umount                                   # ...and the source vanishes
mountpoint -q "$MNT" && fail "unmount did not take effect"
[ -d "$MNT" ] || fail "expected an empty directory to remain after unmount"

_c source status nas >/dev/null 2>&1 \
  && fail "an unmounted BYO source still reported UP (it is an empty dir now)"

# It must be a FAULT, not a skip. A skip raises no flag and marks the unit
# successful, so a permanently vanished mount would quietly stop syncing -- and
# unlike a network blip, a gone mount does not come back by itself.
out=$(_c sync docs 2>&1); rc=$?
[ "$rc" = 0 ] && fail "synced against a vanished mount ($out)" || :
[ "$rc" = 75 ] && fail "a vanished mount was reported as a routine SKIP, so no
    flag is raised and the box stops syncing silently ($out)" || :
printf '%s\n' "$out" | grep -qi "nas" \
  || fail "the refusal did not name the source ($out)"
[ -f "$T/cache/Docs/keep.txt" ] \
  || fail "cache data was destroyed by a vanished mount -- the guard failed"

pass "a real BYO mount: valid as a source, and refused when it vanishes"
