#!/bin/sh
# names.t - a name charon cannot express must be REFUSED, loudly.
#
# MEASURED FAILURE, 2026-09-16. Names were never validated and every caller
# enumerated them with `for x in $(list)`, which word-splits. A profile file a
# user could plausibly create, "My Docs.conf", became TWO phantom profiles:
# charon generated and ARMED charon-sync-My.timer and charon-sync-Docs.timer,
# generated NO prf for the real profile, exited 0, and then `check` reported
# both phantoms [OK]. Every part of that is a convention violation at once --
# silent success on an error path, an armed timer for a profile that does not
# exist, and a declared tree that never synced.
#
# A source name is the worse half, because it does not have to be a filename
# at all: SOURCE=<src>:<subtree> is arbitrary text inside a profile.
. "$(dirname "$0")/lib.sh"
harness_init names

export HOME=$T
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/mnt/Docs" \
         "$T/cache/Docs" "$T/st"
for s in unison mountpoint systemctl systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

cat > "$CFG/sources.d/s.conf" <<EOF
PROVIDER=none
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg sh "$HERE/bin/charon" "$@"
}
SD=$T/xdg/systemd/user
_units() { ls "$SD" 2>/dev/null | tr '\n' ' '; }
_reset() { rm -rf "$T/xdg" "$T/uni"; rm -f "$CFG"/profiles.d/*.conf; }

# --- a VALID config is unaffected: the guard must not cost the normal case ---
_reset
printf 'SOURCE=s:Docs\n' > "$CFG/profiles.d/docs.conf"
_c install >/dev/null 2>&1 || fail "a valid config no longer installs"
[ -f "$T/uni/charon-docs.prf" ] || fail "a valid profile generated no prf"
[ -f "$SD/charon-sync-docs.timer" ] || fail "a valid profile generated no timer"

# --- a profile name with a SPACE: refused, and NOTHING armed ---
_reset
printf 'SOURCE=s:Docs\n' > "$CFG/profiles.d/My Docs.conf"
out=$(_c install 2>&1); rc=$?
[ "$rc" = 0 ] && fail "install exited 0 on a name it cannot express ($out)" || :
printf '%s\n' "$out" | grep -q "My Docs" \
  || fail "the refusal did not name the WHOLE profile, only a split word"
for phantom in charon-sync-My.timer charon-sync-Docs.timer; do
  [ -e "$SD/$phantom" ] \
    && fail "a phantom timer was generated from a split name: $phantom" || :
done
[ -e "$T/uni/charon-My.prf" ] && fail "a phantom prf was generated" || :

# --- check must FAIL on it too, not merely install ---
out=$(_c check 2>&1); rc=$?
[ "$rc" = 0 ] && fail "check passed with an unusable profile name" || :
printf '%s\n' "$out" | grep -q "My Docs" \
  || fail "check did not name the unusable profile ($out)"
# and it must NOT describe the phantoms as healthy, which is what it used to do
printf '%s\n' "$out" | grep -q '\[OK\].*charon-sync-My' \
  && fail "check reported a phantom timer as OK" || :

# --- EVERY bad name is reported, not just the first ---
_reset
printf 'SOURCE=s:Docs\n' > "$CFG/profiles.d/bad one.conf"
printf 'SOURCE=s:Pics\n' > "$CFG/profiles.d/bad two.conf"
out=$(_c check 2>&1)
printf '%s\n' "$out" | grep -q "bad one" \
  || fail "the first bad name was not reported"
printf '%s\n' "$out" | grep -q "bad two" \
  || fail "only the FIRST bad name was reported; the loop stops early"

# --- a SOURCE name is arbitrary config text, not a filename ---
# This is the half a filename-shaped guard would miss entirely.
_reset
printf 'SOURCE=not a source:Docs\n' > "$CFG/profiles.d/docs.conf"
out=$(_c check 2>&1); rc=$?
[ "$rc" = 0 ] && fail "check passed with an unusable SOURCE name ($out)" || :
printf '%s\n' "$out" | grep -qi 'not a source' \
  || fail "check did not name the unusable source ($out)"

# --- a leading dash reads as an option to anything downstream ---
_reset
printf 'SOURCE=s:Docs\n' > "$CFG/profiles.d/-rf.conf"
out=$(_c install 2>&1); rc=$?
[ "$rc" = 0 ] && fail "install accepted a profile named '-rf'" || :

# --- names that ARE legal must keep working: do not over-reject ---
_reset
printf 'SOURCE=s:Docs\n' > "$CFG/profiles.d/my_docs-2.conf"
_c install >/dev/null 2>&1 \
  || fail "a legal name with '_' and '-' and a digit was rejected"
[ -f "$SD/charon-sync-my_docs-2.timer" ] \
  || fail "a legal name generated no timer"

pass "unusable profile and source names are refused loudly, nothing armed"
