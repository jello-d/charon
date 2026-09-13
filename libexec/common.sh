# charon/common.sh - shared preamble for the charon pair: charon-mount (owns the
# rclone FUSE mount) and charon-sync (keeps a local cache in step with it).
# Sourced early via self-location (../libexec/common.sh); set LOG_LEVEL after.
#
# The remote name, the mount path, and the local cache are ONE fact each, shared
# here so a drift cannot make sync a different tree than mount mounts. All
# overridable (env wins) -- for a test, or a second remote. The mount and cache
# DERIVE from the remote name, so a single CHARON_REMOTE override renames all
# three coherently (e.g. dropbox -> ~/dropbox + ~/.dropbox). charon is
# provider-neutral (any rclone remote); the "gdrive" default is just the common
# case, not a Google-Drive assumption.

CHARON_REMOTE=${CHARON_REMOTE:-gdrive}                # rclone remote name
CHARON_MOUNT=${CHARON_MOUNT:-$HOME/$CHARON_REMOTE}    # live FUSE mountpoint
CHARON_CACHE=${CHARON_CACHE:-$HOME/.$CHARON_REMOTE}   # local sync cache (fast)
CHARON_CONFIG=${CHARON_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/charon}

# A SOURCE is one tree to cache plus how it comes to exist. It lives HERE, in
# the shared preamble, because BOTH impls must resolve it identically: the
# mount brings a source up and the sync reconciles it, and if each derived its
# own idea of "which remote, at which path" they could disagree. That is not
# hypothetical -- until this moved here, charon-mount read CHARON_REMOTE
# directly while charon-sync resolved a source, which is exactly why an
# integrator could not safely declare a source at all.
CHARON_SOURCES_DIR=${CHARON_SOURCES_DIR:-$CHARON_CONFIG/sources.d}
CHARON_SOURCE=${CHARON_SOURCE:-default}

# Read one KEY of a source, literally. The 'default' source is IMPLICIT,
# synthesized from CHARON_REMOTE, so a single-remote install needs no file at
# all; writing sources.d/default.conf overrides any key of it.
# TRAITS are facts about what a source IS, measured rather than declared: is it
# case-sensitive, do mtimes stick, does it carry Unix permissions and symlinks.
# They are NOT user preference -- Drive is case-sensitive, SMB and FAT are not,
# and a wrong guess exits a whole profile. They live in STATE, not cache: a
# cleared cache must never silently change sync semantics.
#
# Read at prf RENDER time only, never during a sync pass. A sync runs an
# already-generated prf, so a box that upgrades before it probes keeps syncing
# on its existing profile instead of faulting.
CHARON_STATE=${CHARON_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/charon}
CHARON_TRAITS_DIR=${CHARON_TRAITS_DIR:-$CHARON_STATE/traits}

traits_file() { printf '%s/%s' "$CHARON_TRAITS_DIR" "$1"; }
traits_present() { [ -s "$(traits_file "$1")" ]; }

traits_get() {   # <source> <KEY>
  _tf=$(traits_file "$1")
  [ -f "$_tf" ] || return 0
  sed -n "s/^$2=//p" "$_tf" | head -1
}

source_get() {   # <source> <KEY>
  _sf=$CHARON_SOURCES_DIR/$1.conf
  _v=
  [ -f "$_sf" ] && _v=$(sed -n "s/^$2=//p" "$_sf" | head -1)
  if [ -z "$_v" ] && [ "$1" = default ]; then
    case "$2" in
      MOUNT)      _v=$CHARON_MOUNT ;;
      CACHE_ROOT) _v=$CHARON_CACHE ;;
      REMOTE)     _v=$CHARON_REMOTE ;;
      PROVIDER)   _v=rclone ;;
    esac
  fi
  # quote the pattern so the shell does not tilde-EXPAND it (see profile_get)
  case "$_v" in "~/"*) _v="$HOME/${_v#"~/"}" ;; esac
  printf '%s' "$_v"
}

: "${APP_NAME:=$(basename "$0")}"
: "${LOG_LEVEL:=3}"                    # 1=ERROR 2=WARN 3=INFO 4=TRACE

log_error() {
  [ "$LOG_LEVEL" -ge 1 ] || return 0
  echo "[ERROR] $APP_NAME: $*" >&2
}
log_warn() {
  [ "$LOG_LEVEL" -ge 2 ] || return 0
  echo "[WARN ] $APP_NAME: $*" >&2
}
log_info() {
  [ "$LOG_LEVEL" -ge 3 ] || return 0
  echo "[INFO ] $APP_NAME: $*"
}
log_trace() {
  [ "$LOG_LEVEL" -ge 4 ] || return 0
  echo "[TRACE] $APP_NAME: $*"
}
