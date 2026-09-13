#!/bin/sh
# traits.t - traits are MEASURED, not declared, and the prf is derived from
# them. This is a correctness prerequisite, not tidiness: the old template
# hardcoded cloud assumptions (`fat` = perms 0, dontchmod, links false,
# ignoreinodenumbers), and every one of them is WRONG for an fstab ext4 or NFS
# tree -- it would discard real permissions, refuse real symlinks, and ignore
# stable inodes. Cloud is the special case; a POSIX filesystem is the default.
. "$(dirname "$0")/lib.sh"
harness_init traits

export HOME=$T
export XDG_CONFIG_HOME=$T/.config
export CHARON_REMOTE=testremote
CFG=$XDG_CONFIG_HOME/charon
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" \
         "$T/testremote/Docs" "$T/.testremote"
for s in systemctl unison mountpoint systemd-run sudo; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
printf '#!/bin/sh\ncase "$1" in listremotes) echo testremote: ;; esac\n' \
  > "$T/bin/rclone"
printf 'exit 0\n' >> "$T/bin/rclone"; chmod +x "$T/bin/rclone"
printf '#!/bin/sh\necho "ii  unison  2.53"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
printf 'SUBTREE=Docs\n' > "$CFG/profiles.d/docs.conf"

_charon() { PATH="$T/bin:$PATH" sh "$HERE/bin/charon" "$@"; }
TF=$T/.local/state/charon/traits/default
prf=$T/.unison/charon-docs.prf

# --- render REFUSES without traits: guessing a backend fact is the bug ---
out=$(_charon sync install 2>&1) || :
# install continues (non-destructive) but must have probed rather than guessed
[ -f "$TF" ] || fail "install did not probe a source that had no traits"

# --- the measurement, on a real local dir: a POSIX filesystem ---
grep -q '^WRITABLE=yes$'  "$TF" || fail "writable not measured"
grep -q '^CASE=sensitive$' "$TF" || fail "a local fs is case-sensitive"
grep -q '^TIMES=settable$' "$TF" \
  || fail "a local fs can carry mtimes (a formatted-date compare got this wrong
    once: compare epoch seconds, never a rendered date)"
grep -q '^PERMS=posix$'   "$TF" || fail "a local fs has Unix permissions"
grep -q '^LINKS=yes$'     "$TF" || fail "a local fs has symlinks"
grep -q '^PROBED=' "$TF" || fail "traits not timestamped"

# --- and the prf DERIVED from them: none of the cloud assumptions apply ---
grep -q '^ignorecase = false$' "$prf" || fail "case-sensitive not derived"
grep -q '^times = true$'       "$prf" || fail "settable times not derived"
grep -q '^perms = 0$' "$prf" \
  && fail "POSIX source wrongly told unison to discard permissions" || :
grep -q '^links = false$' "$prf" \
  && fail "POSIX source wrongly told unison to refuse symlinks" || :
grep -q '^ignoreinodenumbers' "$prf" \
  && fail "POSIX source wrongly told unison to ignore stable inodes" || :
grep -q '^fat = ' "$prf" \
  && fail "the fat shorthand is back; traits must be emitted explicitly" || :

# --- probe litter must not survive, and must be ignored even if it did ---
[ -e "$T/testremote/.charon-probe" ] && fail "probe litter left behind" || :
grep -q '^ignore = Name \.charon-probe$' "$prf" \
  || fail "the probe dir is not a Tier 0 ignore"

# --- a re-probe makes the live prf stale, and check must SAY so ---
# This is the loop that closes the design: probe -> check FAILs -> install.
sed -i 's/^CASE=sensitive$/CASE=insensitive/' "$TF"
_charon sync check >"$T/chk.out" 2>&1 && fail "check passed on a stale prf" || :
grep -q '\[FAIL\].*DIFFERS' "$T/chk.out" \
  || fail "check did not report the prf as stale after traits changed"
_charon sync install >/dev/null 2>&1
grep -q '^ignorecase = true$' "$prf" \
  || fail "install did not re-render from the changed traits"
# (not asserting check's exit here: the stubbed systemctl reports no unit
# files, so registration fails for reasons unrelated to traits)
_charon sync check >"$T/chk2.out" 2>&1 || :
grep -q '\[OK\].*charon-docs.prf matches' "$T/chk2.out" \
  || fail "prf still stale after re-rendering from the changed traits"

# --- a source that cannot be probed records NOTHING ---
# An uncertain measurement is worse than none: it becomes an assertion nobody
# re-checks.
cat > "$CFG/sources.d/gone.conf" <<EOF
MOUNT=$T/no/such/tree
CACHE_ROOT=$T/cache/gone
EOF
_charon source probe gone >/dev/null 2>&1 \
  && fail "probe of a missing tree reported success" || :
[ -e "$T/.local/state/charon/traits/gone" ] \
  && fail "a FAILED probe recorded traits anyway" || :

# --- EVERY generated artifact must be diffed, not merely looked for ---
# Only the prf was, for a while: a hand-edited charon-mount.service passed
# check completely unnoticed. A generated file nothing diffs is invisible
# drift, which is the same lesson the prf taught the hard way.
_charon install >/dev/null 2>&1
SD=$XDG_CONFIG_HOME/systemd/user
for g in "$SD/charon-mount.service" "$SD/charon-sync@.service" \
         "$SD/charon-sync-docs.timer" "$T/.unison/charon-docs.prf"; do
  [ -f "$g" ] || fail "expected generated artifact missing: $g"
  cp "$g" "$T/g.bak"
  printf '# sneaky hand edit\n' >> "$g"
  _charon check >/dev/null 2>&1 \
    && fail "check is BLIND to a hand edit of $(basename "$g")" || :
  cp "$T/g.bak" "$g"
done
# (not asserting check's exit: the stubbed systemctl reports no registered
# unit files, so it is non-zero in the sandbox for unrelated reasons)
_charon check >"$T/gen.out" 2>&1 || :
for want in charon-mount.service charon-sync@.service \
            charon-sync-docs.timer charon-docs.prf; do
  grep -q "\[OK\].*$want matches" "$T/gen.out" \
    || fail "$want not reported as matching after restore"
done

pass "traits measured, derived, re-probed, and never guessed"
