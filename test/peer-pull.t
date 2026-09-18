#!/bin/sh
# peer-pull.t - provisioning an rclone remote from a peer, without wrecking
# rclone.conf when it goes wrong.
#
# THE DEFECT THIS PINS (measured 2026-09-17). The pull was a single line:
#
#     ssh "$peer" "rclone config show $REMOTE" >>"$RCLONE_CONF" && ...
#
# The redirect happens BEFORE ssh's status is known, so a connection that
# dropped mid-transfer left a TRUNCATED stanza permanently in the file, ending
# mid-JSON inside an OAuth token:
#
#     [gdrive]
#     type = drive
#     token = {"access_to
#
# Two things then compound it. rclone REPORTS the remote as existing, so
# charon's own already-configured check skips the pull on the next run while the
# remote is unusable. And rclone.conf is shared with every other rclone user on
# the box, so charon corrupted a file it does not own -- one that holds
# credentials, where a half-write is the worst available outcome.
#
# This was the surface I had written off as "needs ssh and a TTY, accept it
# untested". It needs neither: ssh is a stub, and the interesting paths are all
# non-interactive.
. "$(dirname "$0")/lib.sh"
harness_init peer-pull

export HOME=$T
export RCLONE_CONFIG=$T/rc/rclone.conf
mkdir -p "$T/bin" "$T/rc"

# rclone: listremotes answers from the conf file, so "does rclone see it" is a
# real question here rather than a stubbed constant.
cat > "$T/bin/rclone" <<'STUB'
#!/bin/sh
CONF=${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}
case "$1" in
  listremotes) sed -n 's/^\[\(.*\)\]$/\1:/p' "$CONF" 2>/dev/null ;;
esac
exit 0
STUB
chmod +x "$T/bin/rclone"
for s in systemctl mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done

_ssh() {   # <exit-code> <payload...>
  { printf '#!/bin/sh\n'; printf '%s\n' "$2"; printf 'exit %s\n' "$1"; } \
    > "$T/bin/ssh"
  chmod +x "$T/bin/ssh"
}
_pull() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_RCLONE_PEER=peerbox CHARON_REMOTE=gdrive \
    sh "$HERE/libexec/charon-mount" install 2>&1
}
_conf() { printf '[other]\ntype = local\n' > "$T/rc/rclone.conf"; }
_sum()  { md5sum "$T/rc/rclone.conf" | cut -d' ' -f1; }

# --- a DROPPED connection must leave rclone.conf byte-identical ---
# The regression. Partial output on stdout, non-zero exit.
_conf; _before=$(_sum)
_ssh 255 'printf "[gdrive]\ntype = drive\ntoken = {\"access_to"'
out=$(_pull)
[ "$(_sum)" = "$_before" ] \
  || fail "a FAILED pull modified rclone.conf. It holds credentials and is
    shared with every other rclone user on the box:
$(cat "$T/rc/rclone.conf")"
printf '%s\n' "$out" | grep -qi 'UNCHANGED' \
  || fail "the failure did not state that the config was left alone ($out)"
grep -q 'access_to' "$T/rc/rclone.conf" \
  && fail "a truncated OAuth token was written into rclone.conf" || :
# ...and rclone must NOT now believe the remote exists, or the next run skips
# the pull entirely and charon looks configured while being broken.
PATH="$T/bin:$PATH" rclone listremotes | grep -qx 'gdrive:' \
  && fail "a failed pull made rclone report gdrive: as configured" || :

# --- a peer that answers successfully with NOTHING is not a stanza ---
# `rclone config show <name>` exits 0 and prints nothing when the peer does not
# have that remote, so exit status alone cannot be trusted.
_conf; _before=$(_sum)
_ssh 0 ':'
out=$(_pull)
[ "$(_sum)" = "$_before" ] || fail "an EMPTY peer response was appended"
printf '%s\n' "$out" | grep -qi 'usable' \
  || fail "an empty response was not reported as unusable ($out)"

# --- an ssh banner or error on stdout is not a stanza either ---
_conf; _before=$(_sum)
_ssh 0 'printf "Welcome to peerbox!\nLast login: today\n"'
out=$(_pull)
[ "$(_sum)" = "$_before" ] || fail "an ssh BANNER was appended to rclone.conf"

# --- a header with no keys under it is not a stanza ---
_conf; _before=$(_sum)
_ssh 0 'printf "[gdrive]\n"'
_pull >/dev/null 2>&1
[ "$(_sum)" = "$_before" ] || fail "a bodyless [gdrive] header was appended"

# --- the SUCCESS path still works, and is idempotent ---
_conf
_ssh 0 'printf "[gdrive]\ntype = drive\ntoken = {\"ok\":1}\n"'
out=$(_pull)
printf '%s\n' "$out" | grep -qi 'provisioned' \
  || fail "a good pull did not report success ($out)"
[ "$(grep -c '^\[gdrive\]$' "$T/rc/rclone.conf")" = 1 ] \
  || fail "a good pull did not write exactly one stanza"
grep -q '^type = drive$' "$T/rc/rclone.conf" \
  || fail "the stanza body was not written"
# the pre-existing remote must survive untouched
grep -q '^\[other\]$' "$T/rc/rclone.conf" \
  || fail "the pull clobbered an unrelated remote"
_pull >/dev/null 2>&1
[ "$(grep -c '^\[gdrive\]$' "$T/rc/rclone.conf")" = 1 ] \
  || fail "a second pull duplicated the stanza (not idempotent)"

# --- a DUPLICATE stanza is refused, never appended ---
# rclone reads the first and silently ignores the rest, so a second stanza is an
# invisible split brain: charon would look configured while using values nobody
# can see. Forced by a listremotes that does not report it.
printf '[other]\ntype = local\n[gdrive]\ntype = drive\n' > "$T/rc/rclone.conf"
printf '#!/bin/sh\ncase "$1" in listremotes) exit 0 ;; esac\nexit 0\n' \
  > "$T/bin/rclone"
chmod +x "$T/bin/rclone"
out=$(_pull)
printf '%s\n' "$out" | grep -qi 'already has' \
  || fail "a second [gdrive] stanza was not refused ($out)"
[ "$(grep -c '^\[gdrive\]$' "$T/rc/rclone.conf")" = 1 ] \
  || fail "rclone.conf now has a duplicate [gdrive]; rclone reads the first and
    ignores the rest, so the extra one is invisible"

# --- a NEWLINE is written before the stanza ---
# Without it a stanza fuses onto a previous line that lacked a trailing newline
# -- which is precisely the state the old truncating path left behind, so the
# recovery case would have corrupted the file a second way.
cat > "$T/bin/rclone" <<'STUB'
#!/bin/sh
CONF=${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}
case "$1" in
  listremotes) sed -n 's/^\[\(.*\)\]$/\1:/p' "$CONF" 2>/dev/null ;;
esac
exit 0
STUB
chmod +x "$T/bin/rclone"
printf '[other]\ntype = local' > "$T/rc/rclone.conf"   # NO trailing newline
_ssh 0 'printf "[gdrive]\ntype = drive\n"'
_pull >/dev/null 2>&1
grep -q '^\[gdrive\]$' "$T/rc/rclone.conf" \
  || fail "the stanza fused onto a line with no trailing newline:
$(cat "$T/rc/rclone.conf")"

pass "peer pull: validates, appends once, and never corrupts rclone.conf"
