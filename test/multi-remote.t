#!/bin/sh
# multi-remote.t - TWO rclone-backed sources, each with its own mount unit.
#
# THE GAP THIS CLOSES. charon had ONE mount unit with a source baked into it,
# so a second rclone-backed source was accepted by the config, handed profiles
# and sync units, and then never mounted at all. `check` detected the limit and
# FAILED, which was honest, but the limit itself was never rclone's: rclone
# holds many remotes in one config, namespaces its VFS cache per remote, and
# runs one process per mount. It was purely the unit layer.
#
# The hard part was NOT the mount template. It is that the sync unit is
# instanced by PROFILE and the mount by SOURCE, so systemd cannot derive one
# instance name from the other. These assertions pin the per-profile ordering
# drop-in that resolves it, and that it is written for exactly the profiles
# whose source charon actually mounts.
. "$(dirname "$0")/lib.sh"
harness_init multi-remote

export HOME=$T
CFG=$T/cfg
SD=$T/xdg/systemd/user
W=$SD/default.target.wants
export SYSTEMD_STUB_SD=$SD
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$SD" \
         "$T/st" "$T/one/Docs" "$T/two/Pics" "$T/nas/Files" \
         "$T/c1/Docs" "$T/c2/Pics" "$T/c3/Files"

# A systemd model faithful to the ONE behaviour this test turns on: `enable`
# creates a symlink under default.target.wants, and `list-unit-files` reports
# UNIT FILES ONLY -- so a template INSTANCE never appears there, only the
# template itself. The first version of this stub listed enabled instances as
# though they were unit files, which is NOT what systemd does, and it made two
# real bugs pass: the orphan check and uninstall both enumerated instances that
# way and found nothing on a real box. A stub that answers a query differently
# from the real tool makes its test worse than no test.
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
SD=$SYSTEMD_STUB_SD; W=$SD/default.target.wants
mkdir -p "$W"
a=
for x in "$@"; do
  case "$x" in
    --user|--now|--no-legend|-q|--quiet|--all) ;;
    *) a="$a $x" ;;
  esac
done
# shellcheck disable=SC2086
set -- $a
case "${1:-}" in
  enable)  shift; for u in "$@"; do ln -sfn "$SD/${u%%@*}@.service" "$W/$u"
           done ;;
  disable) shift; for u in "$@"; do rm -f "$W/$u"; done ;;
  is-enabled|is-active) [ -e "$W/$2" ] || [ -e "$SD/$2" ] ;;
  list-unit-files)
    pat=${2:-}
    for f in "$SD"/*.service "$SD"/*.timer; do
      [ -e "$f" ] || continue
      n=$(basename "$f")
      case "$pat" in
        "") echo "$n enabled" ;;
        # shellcheck disable=SC2254
        *) case "$n" in $pat) echo "$n enabled" ;; esac ;;
      esac
    done 2>/dev/null ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/bin/systemctl"

# rclone: both remotes exist and answer. mountpoint says yes so the gate is not
# what this test is measuring.
cat > "$T/bin/rclone" <<'STUB'
#!/bin/sh
case "$1" in
  listremotes) printf 'one:\ntwo:\n' ;;
  config)      echo "type = drive" ;;
  about)       exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/rclone"
for s in unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

# TWO rclone-backed sources, plus a BYO one so the mixed case is covered in the
# same run: the drop-in must appear for the mounted pair and NOT for the third.
cat > "$CFG/sources.d/one.conf" <<EOF
PROVIDER=rclone
REMOTE=one
MOUNT=$T/one
CACHE_ROOT=$T/c1
EOF
cat > "$CFG/sources.d/two.conf" <<EOF
PROVIDER=rclone
REMOTE=two
MOUNT=$T/two
CACHE_ROOT=$T/c2
EOF
cat > "$CFG/sources.d/nas.conf" <<EOF
PROVIDER=none
MOUNT=$T/nas
CACHE_ROOT=$T/c3
EOF
printf 'SOURCE=one:Docs\n'  > "$CFG/profiles.d/docs.conf"
printf 'SOURCE=two:Pics\n'  > "$CFG/profiles.d/pics.conf"
printf 'SOURCE=nas:Files\n' > "$CFG/profiles.d/files.conf"

# Pre-seed traits so install renders prfs without probing: the probe WRITES to
# the mount, and what is under test here is the unit layer.
for s in one two nas; do
  cat > "$T/st/$s" <<EOF
PROBED=2026-09-15T00:00:00+00:00
CASE=sensitive
TIMES=settable
PERMS=none
LINKS=no
FSTYPE=fuseblk
EOF
done

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg sh "$HERE/bin/charon" "$@"
}

# --- a legacy singleton is present, as on any box upgrading across this ---
printf '[Unit]\nDescription=old\n' > "$SD/charon-mount.service"
mkdir -p "$W"; ln -sfn "$SD/charon-mount.service" "$W/charon-mount.service"

_c install >/dev/null 2>&1 || fail "install failed with two rclone sources"

# --- BOTH sources get an instance, enabled and active ---
for s in one two; do
  [ -e "$W/charon-mount@$s.service" ] \
    || fail "source '$s' got no mount instance; only one remote is mounted"
done

# --- the retired singleton is swept, not left fighting for the mountpoint ---
[ -e "$W/charon-mount.service" ] \
  && fail "the legacy singleton is still enabled after install" || :
[ -f "$SD/charon-mount.service" ] \
  && fail "the legacy singleton unit file survived install" || :

# --- ONE template, and nothing source-specific baked into it ---
[ -f "$SD/charon-mount@.service" ] || fail "no charon-mount@.service template"
for s in one two; do
  grep -q "CHARON_SOURCE=$s" "$SD/charon-mount@.service" \
    && fail "the template bakes source '$s'; it must be generic (%i)" || :
done
grep -q 'ExecStart=.*charon source up %i' "$SD/charon-mount@.service" \
  || fail "the template does not start the instance's own source"

# --- THE ORDERING DROP-IN: each profile waits on ITS OWN source's mount ---
# The whole reason this was thought hard. Getting these crossed would order a
# profile behind a remote it does not use, and leave its real one unordered.
_dp() { echo "$SD/charon-sync@$1.service.d/10-source.conf"; }
grep -q 'After=charon-mount@one\.service' "$(_dp docs)" \
  || fail "profile docs is not ordered after ITS source's mount (one)"
grep -q 'After=charon-mount@two\.service' "$(_dp pics)" \
  || fail "profile pics is not ordered after ITS source's mount (two)"
grep -q 'charon-mount@two' "$(_dp docs)" \
  && fail "profile docs is ordered after the WRONG source's mount" || :

# --- a PROVIDER=none profile gets NO drop-in: charon owns no unit for it ---
[ -e "$(_dp files)" ] \
  && fail "a BYO-source profile was ordered after a mount charon does not own" \
  || :

# --- check PASSES with two remotes. Under the old singleton this was a hard
# --- FAIL ("N rclone-backed sources ... all but one are NOT mounted").
out=$(_c check 2>&1); rc=$?
[ "$rc" = 0 ] || fail "check failed with two rclone sources: $out"
printf '%s\n' "$out" | grep -q 'charon-mount@one.service active' \
  || fail "check does not assert the first source is mounted"
printf '%s\n' "$out" | grep -q 'charon-mount@two.service active' \
  || fail "check does not assert the SECOND source is mounted"

# --- the drop-in is GENERATED, so a hand edit of it must be caught ---
# Everything charon writes gets diffed by check; a new artifact that skipped
# that rule would be exactly the blind spot the mount unit used to be.
cp "$(_dp pics)" "$T/d.bak"
printf '# sneaky hand edit\n' >> "$(_dp pics)"
_c check 2>&1 | grep -q '\[FAIL\].*ordering drop-in.*DIFFERS' \
  || fail "check is blind to a hand-edited ordering drop-in"
cp "$T/d.bak" "$(_dp pics)"
_c check >/dev/null 2>&1 || fail "check did not go green again after restore"

# --- a source that goes away must not leave a silently dead instance ---
rm -f "$CFG/sources.d/two.conf"
out=$(_c check 2>&1); rc=$?
[ "$rc" = 0 ] \
  && fail "check passed with an instance enabled for a deleted source"
printf '%s\n' "$out" | grep -q "charon-mount@two.service" \
  || fail "check did not name the orphaned instance ($out)"
cat > "$CFG/sources.d/two.conf" <<EOF
PROVIDER=rclone
REMOTE=two
MOUNT=$T/two
CACHE_ROOT=$T/c2
EOF

# --- repointing a profile moves its ordering with it ---
printf 'SOURCE=two:Docs\n' > "$CFG/profiles.d/docs.conf"
_c install >/dev/null 2>&1 || fail "reinstall after repointing failed"
grep -q 'After=charon-mount@two\.service' "$(_dp docs)" \
  || fail "repointing a profile did not move its mount ordering"
grep -q 'charon-mount@one' "$(_dp docs)" \
  && fail "the old source's ordering survived a repoint" || :

# --- uninstall removes EVERY instance, not just one ---
_c uninstall >/dev/null 2>&1 || fail "uninstall failed"
for s in one two; do
  [ -e "$W/charon-mount@$s.service" ] \
    && fail "uninstall left source '$s' enabled" || :
done
[ -e "$(_dp docs)" ] && fail "uninstall left an ordering drop-in behind" || :
[ -d "$T/one" ] && [ -d "$T/two" ] \
  || fail "uninstall removed a mountpoint; it must touch only units"

pass "two rclone sources: one unit each, per-profile ordering, clean teardown"
