#!/bin/sh
# scenario.t - install a whole charon, PROVE IT GREEN, then break one thing at a
# time and require check to catch each.
#
# WHY THIS EXISTS AS A TEST. Run by hand on 2026-09-17 it found two defects the
# 18-test suite could not, and BOTH surfaced from the baseline refusing to go
# green, before a single breakage was applied: the unison prerequisite asking
# "is it a dpkg package" instead of "is it runnable", and a BYO-only install
# being unable to pass check at all. Individual tests each stub away most of the
# system; only an end-to-end install exercises the interactions between them.
#
# THE BASELINE GATE IS THE LOAD-BEARING PART. The first hand-run of this was
# worthless: a stub typo left the baseline RED, so every breakage dutifully
# reported "caught" and the whole sweep read as a clean bill of health. A
# breakage sweep over a red baseline measures nothing at all, so this refuses to
# proceed until install and check are both 0.
. "$(dirname "$0")/lib.sh"
harness_init scenario

export HOME=$T
export XDG_CONFIG_HOME=$T/xdg
CFG=$T/cfg
SD=$T/xdg/systemd/user
W=$SD/default.target.wants
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$SD" "$W" "$T/st" \
         "$T/mnt/Docs" "$T/cache/Docs"
echo content > "$T/mnt/Docs/a.txt"
echo content > "$T/cache/Docs/a.txt"

# A systemd model faithful enough that check's questions are ANSWERABLE. A stub
# that exits 0 and prints nothing makes check fail for reasons unrelated to
# charon, and then nobody asserts the verdict -- which is exactly how the
# BYO-only defect hid inside provider.t for as long as it did.
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
SD=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
W=$SD/default.target.wants
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
rc=0
case "${1:-}" in
  # enable links into default.target.wants, which is where systemd records
  # enablement. A TEMPLATE INSTANCE links to the template; anything else links
  # to itself. Getting that wrong builds a DANGLING link, and `[ -e ]` is FALSE
  # for a dangling link, so is-enabled then answered "no" for every timer.
  enable)  shift
           for u in "$@"; do
             case "$u" in
               *@*.service) t=$SD/${u%%@*}@.service ;;
               *)           t=$SD/$u ;;
             esac
             ln -sfn "$t" "$W/$u"
           done ;;
  disable) shift; for u in "$@"; do rm -f "$W/$u"; done ;;
  # ENABLEMENT is the wants link ONLY. Accepting the presence of the unit FILE
  # too made "the timer disabled" undetectable: the file is still there, it is
  # just no longer armed, which is exactly the state being tested.
  # The RESULT MUST REACH THE CALLER. The unconditional `exit 0` this stub
  # ended with discarded it, so is-enabled answered "yes" forever and "the timer
  # disabled" was undetectable -- the stub, not charon, was the reason.
  is-enabled|is-active) [ -L "$W/$2" ] || rc=1 ;;
  list-unit-files)
    pat=${2:-}
    for f in "$SD"/*.service "$SD"/*.timer; do
      [ -e "$f" ] || continue
      n=${f##*/}
      case "$pat" in
        "") echo "$n enabled" ;;
        # shellcheck disable=SC2254
        *) case "$n" in $pat) echo "$n enabled" ;; esac ;;
      esac
    done 2>/dev/null ;;
  # -p <prop> --value: print the VALUE only, which is what charon asks for.
  # Echoing "ExecMainStatus=0" made profile_outcome read a garbage status and
  # the baseline gate correctly refused it.
  show)
    for x in "$@"; do
      case "$x" in
        Result)          echo success ;;
        ExecMainStatus)  echo 0 ;;
        ExecMainStartTimestamp) echo "Wed 2026-09-17 12:00:00 UTC" ;;
        LastTriggerUSec) echo "Wed 2026-09-17 12:00:00 UTC" ;;
      esac
    done ;;
esac
exit $rc
STUB
chmod +x "$T/bin/systemctl"
cat > "$T/bin/rclone" <<'STUB'
#!/bin/sh
case "$1" in
  listremotes) printf 'gd:\n' ;;
  config)      echo "type = drive" ;;
  about)       exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/rclone"
for s in unison mountpoint systemd-run; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\necho "notify $*" >> "%s"\nexit 0\n' "$T/notify.log" \
  > "$T/bin/rec-notify"
chmod +x "$T/bin/rec-notify"

cat > "$CFG/sources.d/gd.conf" <<EOF
PROVIDER=rclone
REMOTE=gd
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=gd:Docs\n' > "$CFG/profiles.d/docs.conf"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni CHARON_NOTIFY=rec-notify sh "$HERE/bin/charon" "$@"
}

#### THE BASELINE GATE ####
_c install >/dev/null 2>&1; _i=$?
_c check >/dev/null 2>&1;   _k=$?
[ "$_i" = 0 ] || fail "BASELINE install exited $_i; a breakage sweep over a
  broken install measures nothing. $(_c install 2>&1 | tail -5)"
[ "$_k" = 0 ] || fail "BASELINE check exited $_k on a FRESH install; every
  breakage below would report 'caught' for the wrong reason.
$(_c check 2>&1 | grep -v '\[OK\]')"

# Every breakage: apply, require check to FAIL, restore, require check GREEN
# again. The restore assertion matters as much as the catch -- a check that
# latches on and never recovers is unusable, and an un-restored breakage would
# make every later case pass for free.
_n=0
brk() {   # <label> <break> <restore>
  _n=$((_n + 1))
  eval "$2"
  if _c check >/dev/null 2>&1; then
    eval "$3"
    fail "check MISSED: $1"
  fi
  eval "$3"
  _c check >/dev/null 2>&1 \
    || fail "after restoring ($1) check is still red, so either the restore is
      wrong or check latched: $(_c check 2>&1 | grep -v '\[OK\]')"
}

#### generated artifacts: deleted, and hand-edited ####
brk "the prf deleted" \
  'rm -f "$T/uni/charon-docs.prf"' '_c install >/dev/null 2>&1'
brk "the prf hand-edited" \
  'echo "# sneaky" >> "$T/uni/charon-docs.prf"' '_c install >/dev/null 2>&1'
brk "the timer deleted" \
  'rm -f "$SD/charon-sync-docs.timer"' '_c install >/dev/null 2>&1'
brk "the timer hand-edited" \
  'echo "# sneaky" >> "$SD/charon-sync-docs.timer"' '_c install >/dev/null 2>&1'
brk "the sync unit hand-edited" \
  'echo "# sneaky" >> "$SD/charon-sync@.service"' '_c install >/dev/null 2>&1'
brk "the mount template hand-edited" \
  'echo "# sneaky" >> "$SD/charon-mount@.service"' '_c install >/dev/null 2>&1'
brk "the ordering drop-in deleted" \
  'rm -rf "$SD/charon-sync@docs.service.d"' '_c install >/dev/null 2>&1'
brk "the ordering drop-in hand-edited" \
  'echo "# sneaky" >> "$SD/charon-sync@docs.service.d/10-source.conf"' \
  '_c install >/dev/null 2>&1'

#### enablement: the unit exists but is not armed ####
brk "the timer disabled" \
  'rm -f "$W/charon-sync-docs.timer"' \
  'ln -sfn "$SD/charon-sync-docs.timer" "$W/charon-sync-docs.timer"'
brk "the mount instance disabled" \
  'rm -f "$W/charon-mount@gd.service"' \
  'ln -sfn "$SD/charon-mount@.service" "$W/charon-mount@gd.service"'
brk "an ORPHAN mount instance for a source that does not exist" \
  'ln -sfn "$SD/charon-mount@.service" "$W/charon-mount@ghost.service"' \
  'rm -f "$W/charon-mount@ghost.service"'
brk "the retired singleton reappears" \
  'printf "[Unit]\n" > "$SD/charon-mount.service"' \
  'rm -f "$SD/charon-mount.service"'

#### config and state ####
brk "the source config deleted (profiles name an undefined source)" \
  'mv "$CFG/sources.d/gd.conf" "$T/gd.away"' \
  'mv "$T/gd.away" "$CFG/sources.d/gd.conf"'
brk "MOUNT points at a tree that is not there" \
  'sed -i "s,MOUNT=$T/mnt,MOUNT=$T/gone," "$CFG/sources.d/gd.conf"' \
  'sed -i "s,MOUNT=$T/gone,MOUNT=$T/mnt," "$CFG/sources.d/gd.conf"'
brk "the cache root removed" \
  'mv "$T/cache" "$T/cache.away"' 'mv "$T/cache.away" "$T/cache"'
brk "a profile name charon cannot express" \
  'printf "SOURCE=gd:Other\n" > "$CFG/profiles.d/bad name.conf"' \
  'rm -f "$CFG/profiles.d/bad name.conf"'
brk "two profiles on the SAME (source, subtree)" \
  'cp "$CFG/profiles.d/docs.conf" "$CFG/profiles.d/dup.conf"' \
  'rm -f "$CFG/profiles.d/dup.conf"'
brk "MOUNT == CACHE_ROOT" \
  'sed -i "s,CACHE_ROOT=$T/cache,CACHE_ROOT=$T/mnt," "$CFG/sources.d/gd.conf"' \
  'sed -i "s,CACHE_ROOT=$T/mnt,CACHE_ROOT=$T/cache," "$CFG/sources.d/gd.conf"'
brk "the notify seam configured but unreachable" \
  'sed -i "s,CHARON_NOTIFY=.*,CHARON_NOTIFY=no-such-notifier," \
     "$SD/charon-sync@.service"' \
  '_c install >/dev/null 2>&1'

# Traits deleted: check must FAIL, and must say WHAT TO DO. The prf is DERIVED
# from measured traits, so without them it cannot be re-rendered and therefore
# cannot be verified -- which is the intended design ("probe -> check FAILs ->
# install"), not a gap. I first wrote this case asserting the OPPOSITE, on a
# misreading of the no-migration-cliff guarantee: that guarantee is that a SYNC
# keeps running on its existing prf, not that check stays quiet.
#
# What makes it a good failure rather than a confusing one is the guidance, so
# that is what is asserted.
mv "$T/st/gd" "$T/st-away"
out=$(_c check 2>&1); rc=$?
[ "$rc" = 0 ] && fail "check passed with NO measured traits, so the prf could
  not be verified at all and nothing said so" || :
printf '%s\n' "$out" | grep -q 'charon source probe' \
  || fail "check reported unrenderable traits without telling the reader to
    probe; a verdict with no remedy sends them hunting ($out)"
mv "$T/st-away" "$T/st/gd"
_c check >/dev/null 2>&1 || fail "check stayed red after restoring traits"
_n=$((_n + 1))

pass "$_n breakages, each caught and each recovered, over a proven baseline"
