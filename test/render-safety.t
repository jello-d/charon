#!/bin/sh
# render-safety.t - a failed render must never destroy the working artifact.
#
# THE BUG THIS CLOSES, found on a LIVE BOX 2026-09-26 by running
# `LOG_LEVEL=3 charon sync install`:
#
#   resolved_notify's stdout IS its return value, read by
#   `$(resolved_notify)`. It also called log_info, which writes to STDOUT. So
#   at LOG_LEVEL>=3 the baked notify path became
#   "[INFO ] ... resolved to /home/jello/bin/x" + newline + the real path --
#   MULTI-LINE. render_sync_unit feeds that to sed as a replacement, a
#   multi-line sed replacement is an ERROR ("unterminated `s' command"), sed
#   produced nothing, and install -- which redirected the renderer straight at
#   the unit file -- left charon-sync@.service ZERO BYTES.
#
# Latent until then only because charon-sync pins LOG_LEVEL=2, so log_info was
# suppressed and nobody had installed at a higher level. Anyone debugging with
# LOG_LEVEL=3 or 4 would have silently lost their sync unit.
#
# Two independent defects, so two independent fixes, and both are asserted here.
# The second is the one that matters: it makes ANY render failure non
# destructive, not just this one.
. "$(dirname "$0")/lib.sh"
harness_init render-safety

export CHARON_LIBEXEC=$HERE/libexec
export HOME=$T
export CHARON_CONFIG=$T/cfg
export CHARON_TRAITS_DIR=$T/st
export CHARON_STATE=$T/state
export UNISON_DIR=$T/uni
mkdir -p "$T/cfg/profiles.d" "$T/cfg/sources.d" "$T/st" "$T/uni" "$T/bin" \
         "$T/.cache" "$T/state"

CHARON_LIB_ONLY=1 . "$HERE/libexec/charon-sync"
_self=$HERE/libexec/charon-sync

# ----------------------------------------------------------------- part 1 ----
# A FUNCTION WHOSE STDOUT IS A VALUE MUST NOT LOG TO STDOUT.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/mynotifier"
chmod +x "$T/bin/mynotifier"

for lvl in 1 2 3 4; do
  _v=$(PATH="$T/bin:$PATH" LOG_LEVEL=$lvl CHARON_NOTIFY=mynotifier \
         resolved_notify 2>/dev/null)
  [ "$_v" = "$T/bin/mynotifier" ] \
    || fail "at LOG_LEVEL=$lvl resolved_notify returned
    [$_v]
  instead of the bare path [$T/bin/mynotifier]. Its stdout IS the value, so a
  log line on stdout becomes part of it -- and a multi-line value makes the
  renderer's sed fail, which used to blank the unit file."
  # And it must be ONE line, which is the property sed actually cares about.
  [ "$(printf '%s' "$_v" | wc -l)" = 0 ] \
    || fail "at LOG_LEVEL=$lvl the resolved notify value spans multiple lines"
done

# The renderer survives every level, which is the consequence that bit us.
for lvl in 1 2 3 4; do
  _n=$(PATH="$T/bin:$PATH" LOG_LEVEL=$lvl CHARON_NOTIFY=mynotifier \
         resolved_notify 2>/dev/null)
  _out=$(render_sync_unit "$_n" 2>/dev/null) \
    || fail "render_sync_unit FAILED at LOG_LEVEL=$lvl"
  printf '%s\n' "$_out" \
    | grep -qx "Environment=CHARON_NOTIFY=$T/bin/mynotifier" \
    || fail "at LOG_LEVEL=$lvl the rendered unit does not carry the resolved
    notify path; got: $(printf '%s\n' "$_out" | grep CHARON_NOTIFY)"
done

# ----------------------------------------------------------------- part 2 ----
# THE DEFENCE THAT GENERALISES: install_artifact must keep the existing file
# when a render fails, instead of truncating it first and leaving a husk.
LIVE=$T/live.artifact
printf 'the working version\n' > "$LIVE"

# Every failure mode is checked for a leftover temp IMMEDIATELY, not at the end:
# consecutive calls in one process reuse the same $$ temp name, so a later call
# cleans up an earlier call's leftover and the assertion cannot see it. Found by
# mutation -- dropping the rm on the failure path survived a check done later.
_no_temp() {   # <what just happened>
  [ -z "$(find "$T" -maxdepth 1 -name '*.charon-new.*' 2>/dev/null)" ] \
    || fail "install_artifact left its temp behind after $1:
    $(find "$T" -maxdepth 1 -name '*.charon-new.*')"
}

# A renderer that FAILS and writes NOTHING.
_boom() { echo "boom" >&2; return 3; }
install_artifact "$LIVE" _boom \
  && fail "install_artifact reported success for a renderer that FAILED"
[ "$(cat "$LIVE")" = "the working version" ] \
  || fail "a FAILED render destroyed the live artifact; it now holds:
  [$(cat "$LIVE")]"
_no_temp "a failed render"

# A renderer that FAILS having already written SOME output. Only the exit
# STATUS can catch this one -- the output is non-empty, so the size check
# passes it -- and it is the realistic shape: sed emitting several lines and
# then erroring leaves exactly this.
_partial() { printf 'half a unit\n'; return 4; }
install_artifact "$LIVE" _partial \
  && fail "install_artifact accepted a render that wrote output and THEN failed"
[ "$(cat "$LIVE")" = "the working version" ] \
  || fail "a PARTIAL render replaced the live artifact with its half-output:
  [$(cat "$LIVE")]"
_no_temp "a partial render"

# A renderer that SUCCEEDS but emits nothing. Only the size check can catch
# this one -- sed exits 0 in some failure modes and simply prints nothing -- so
# an exit status alone is not enough to trust.
_empty() { return 0; }
install_artifact "$LIVE" _empty \
  && fail "install_artifact accepted an EMPTY render"
[ "$(cat "$LIVE")" = "the working version" ] \
  || fail "an EMPTY render destroyed the live artifact"
_no_temp "an empty render"

# A renderer that works replaces it, atomically.
_good() { printf 'the new version\n'; }
install_artifact "$LIVE" _good || fail "install_artifact rejected a good render"
[ "$(cat "$LIVE")" = "the new version" ] \
  || fail "install_artifact did not install a good render"
_no_temp "a good render"

# It creates the artifact when there is none to keep.
rm -f "$LIVE"
install_artifact "$LIVE" _good || fail "install_artifact failed on a fresh file"
[ -s "$LIVE" ] || fail "install_artifact wrote nothing on a fresh file"

# ----------------------------------------------------------------- part 3 ----
# END TO END: a real install at LOG_LEVEL=4 must leave a VALID sync unit. This
# is the exact command that blanked the unit on a live box.
cat > "$T/st/s" <<'EOF'
PROBED=2026-01-01T00:00:00+00:00
WRITABLE=yes
CASE=sensitive
TIMES=settable
PERMS=none
LINKS=no
FSTYPE=ext4
EOF
cat > "$T/cfg/sources.d/s.conf" <<EOF
PROVIDER=none
MOUNT=$T/src
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=s:D\n' > "$T/cfg/profiles.d/docs.conf"
mkdir -p "$T/src/D" "$T/cache/D" "$T/xdg/systemd/user"
for s in systemctl systemd-run mountpoint unison; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"; done
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"

SVC=$T/xdg/systemd/user/charon-sync@.service
for lvl in 2 4; do
  rm -f "$SVC"
  PATH="$T/bin:/usr/bin:/bin" LOG_LEVEL=$lvl CHARON_NOTIFY=mynotifier \
    XDG_CONFIG_HOME=$T/xdg sh "$HERE/libexec/charon-sync" install \
    >/dev/null 2>&1 || fail "install failed at LOG_LEVEL=$lvl"
  [ -s "$SVC" ] \
    || fail "install at LOG_LEVEL=$lvl left charon-sync@.service EMPTY (or
    absent). This is the live bug: a log line on the notify value's stdout made
    the renderer's sed fail, and the redirect had already truncated the file."
  grep -qx "Environment=CHARON_NOTIFY=$T/bin/mynotifier" "$SVC" \
    || fail "at LOG_LEVEL=$lvl the installed unit does not carry the resolved
    notify path: $(grep CHARON_NOTIFY "$SVC")"
  grep -q '^ExecStart=' "$SVC" \
    || fail "at LOG_LEVEL=$lvl the installed unit has no ExecStart"
done

# A GENUINE RENDER FAILURE DURING A REAL INSTALL must leave the WORKING unit in
# place. Induced honestly rather than by stubbing: render_sync_unit substitutes
# with `sed -e "s|@CHARON_NOTIFY@|$1|g"`, so a notify path containing sed's own
# delimiter breaks the expression. That is also a real (if narrow) edge -- a
# filename may contain '|' -- and the right behaviour for it is exactly the
# right behaviour for any render failure.
cp "$SVC" "$T/known-good"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pipe|notifier"
chmod +x "$T/bin/pipe|notifier"
PATH="$T/bin:/usr/bin:/bin" CHARON_NOTIFY='pipe|notifier' \
  XDG_CONFIG_HOME=$T/xdg sh "$HERE/libexec/charon-sync" install \
  >/dev/null 2>&1 \
  && fail "install reported SUCCESS while it could not render the sync unit"
[ -s "$SVC" ] \
  || fail "a render failure during install BLANKED the live sync unit; the
  whole point of rendering to a temp is that the working artifact survives"
cmp -s "$SVC" "$T/known-good" \
  || fail "a render failure during install REPLACED the working sync unit:
  $(cat "$SVC")"
rm -f "$T/bin/pipe|notifier"
# And a normal install puts it back to a good state for the check below.
PATH="$T/bin:/usr/bin:/bin" CHARON_NOTIFY=mynotifier \
  XDG_CONFIG_HOME=$T/xdg sh "$HERE/libexec/charon-sync" install \
  >/dev/null 2>&1 || fail "the recovery install failed"

# ...and a check right after agrees, at both levels, which is the property an
# integrator actually depends on.
PATH="$T/bin:/usr/bin:/bin" XDG_CONFIG_HOME=$T/xdg \
  sh "$HERE/libexec/charon-sync" check 2>&1 \
  | grep -q '\[OK\].*charon-sync@.service matches' \
  || fail "check does not consider the unit installed at LOG_LEVEL=4 to match
  this version's template"

pass "a failed render keeps the working artifact; stdout is never a log channel"
