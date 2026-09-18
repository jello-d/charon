#!/bin/sh
# status.t - the HUMAN view: it must never fail, never write, and still answer.
#
# `charon status` is deliberately not a verdict -- `check` is that. status
# exists to be read, so its contract is unusual and worth pinning explicitly:
#
#   1. IT NEVER WRITES. Traits are measured by a PROBE, and a probe writes into
#      the source. status must not probe, or merely looking at a Drive-backed
#      cache would put files on the remote -- the exact incidental-write class
#      this project spent its history removing.
#   2. IT NEVER FAILS. A human runs it precisely when something is wrong, so
#      exiting non-zero on a broken config would make the diagnostic unusable at
#      the moment it is needed. Every breakage below must still produce output
#      and exit 0.
#   3. It answers the questions it exists for: which source, which roots, which
#      pair each profile reconciles, the cadence, and the last outcome WITH AN
#      AGE (a bare "OK" cannot distinguish a pass a minute ago from one last
#      week).
. "$(dirname "$0")/lib.sh"
harness_init status

export HOME=$T
export XDG_CONFIG_HOME=$T/xdg
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/st" \
         "$T/mnt/Docs" "$T/cache/Docs" "$T/xdg/systemd/user"
echo content > "$T/mnt/Docs/a.txt"

for s in unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
case " $* " in
  *" show "*)
    for x in "$@"; do
      case "$x" in
        Result)          echo success ;;
        ExecMainStatus)  echo 0 ;;
        ExecMainStartTimestamp) echo "Fri 2026-09-18 12:00:00 EDT" ;;
        LastTriggerUSec) echo "Fri 2026-09-18 12:00:00 EDT" ;;
      esac
    done ;;
esac
exit 0
STUB
chmod +x "$T/bin/systemctl"
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

cat > "$CFG/sources.d/nas.conf" <<EOF
PROVIDER=none
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=nas:Docs\nINTERVAL=17m\nCONFLICT=local\nDELETE=never\n' \
  > "$CFG/profiles.d/docs.conf"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni sh "$HERE/bin/charon" "$@"
}
# A fingerprint of everything under the source: names, sizes and mtimes. If
# status writes ANYTHING -- a probe file, a touched mtime -- this moves.
_fp() { find "$T/mnt" -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum; }

_c install >/dev/null 2>&1 || fail "install failed (status test setup)"

# --- IT NEVER WRITES, before or after traits exist ---
_before=$(_fp)
out=$(_c status 2>&1); rc=$?
[ "$(_fp)" = "$_before" ] \
  || fail "status WROTE into the source. On a Drive-backed source that puts
    files on the remote just for looking at it."
[ "$rc" = 0 ] || fail "status on a healthy tree exited $rc"

# --- it answers the questions it exists for ---
printf '%s\n' "$out" | grep -q "nas" \
  || fail "status did not name the source ($out)"
printf '%s\n' "$out" | grep -q "$T/mnt" \
  || fail "status did not show the source root"
printf '%s\n' "$out" | grep -q "$T/cache" \
  || fail "status did not show the cache root"
printf '%s\n' "$out" | grep -q 'docs' \
  || fail "status did not name the profile"
printf '%s\n' "$out" | grep -q 'nas:Docs' \
  || fail "status did not show WHICH PAIR the profile reconciles ($out)"
printf '%s\n' "$out" | grep -q '17m' \
  || fail "status did not show the configured cadence ($out)"
# The EFFECTIVE policy, not the default: a reader checking why a conflict
# resolved a particular way needs the value actually in force.
printf '%s\n' "$out" | grep -qi 'conflict=local' \
  || fail "status did not show the effective CONFLICT policy ($out)"
printf '%s\n' "$out" | grep -qi 'delete=never' \
  || fail "status did not show the effective DELETE policy ($out)"
# An outcome WITH AN AGE. "OK" alone cannot tell a pass a minute ago from one
# last week, which is the single thing a human is looking for.
printf '%s\n' "$out" | grep -qiE 'ago|never|not run' \
  || fail "status reported an outcome with NO AGE ($out)"

#### IT NEVER FAILS, however broken the tree is ####
# Each of these is a state a human would actually run status to diagnose.
_still_ok() {   # <label>
  _so=$(_c status 2>&1); _sr=$?
  [ "$_sr" = 0 ] || fail "status exited $_sr with $1; it is the diagnostic a
    human reaches for WHEN things are broken, so it must still answer:
$_so"
  [ -n "$_so" ] || fail "status printed NOTHING with $1"
  [ "$(_fp)" = "$_before" ] || fail "status wrote into the source with $1"
}

mv "$T/st/nas" "$T/st.away";                   _still_ok "no measured traits"
mv "$T/st.away" "$T/st/nas"
mv "$T/uni/charon-docs.prf" "$T/prf.away";     _still_ok "no generated prf"
mv "$T/prf.away" "$T/uni/charon-docs.prf"
mv "$CFG/sources.d/nas.conf" "$T/src.away";    _still_ok "an undefined source"
mv "$T/src.away" "$CFG/sources.d/nas.conf"
mv "$T/cache" "$T/cache.away";                 _still_ok "no cache root"
mv "$T/cache.away" "$T/cache"
printf 'INTERVAL=5m\n' > "$CFG/profiles.d/nosrc.conf"
_still_ok "a profile naming no source at all"
rm -f "$CFG/profiles.d/nosrc.conf"
rm -rf "$T/xdg/systemd/user"
_still_ok "no generated units"
mkdir -p "$T/xdg/systemd/user"

# --- with NO profiles at all it must still say something useful ---
rm -f "$CFG"/profiles.d/*.conf
out=$(_c status 2>&1); rc=$?
[ "$rc" = 0 ] || fail "status exited $rc with no profiles configured"
[ -n "$out" ] || fail "status said nothing at all with no profiles"

# --- and with no SCHEDULER, since status must work on a box without systemd ---
printf 'SOURCE=nas:Docs\n' > "$CFG/profiles.d/docs.conf"
_nosd=$(path_without systemctl systemd-run) || exit 1
out=$(PATH="$T/bin:$_nosd" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
  UNISON_DIR=$T/uni sh "$HERE/bin/charon" status 2>&1); rc=$?
[ "$rc" = 0 ] || fail "status exited $rc with no systemd at all ($out)"
[ -n "$out" ] || fail "status printed nothing without systemd"

pass "status: never writes, never fails, and answers what it is for"
