#!/bin/sh
# inhibitor.t - a DENIED sleep inhibitor must DEGRADE the pass, never cancel it.
#
# THE GAP THIS CLOSES. This is the only production defect in charon's history
# whose fix had no test at all. `systemd-inhibit --mode=block` needs polkit
# authorization, and a --user manager session with NO SEAT does not get it:
# polkit answers "Access denied ... requires interactive authentication" and
# systemd-inhibit exits 1. The whole pass used to hang off that one command, so
# a denial did not degrade the sync, it CANCELLED it -- manifestor failed 5 of
# 6 timed documents runs and 2 of 3 media runs that way, while manifold (a
# seated session) was perfectly clean, which made a latent bug look
# box-specific.
#
# skip.t leaves systemd-inhibit ABSENT, which exercises a DIFFERENT branch:
# absent means the probe command itself cannot run. The dangerous case is
# PRESENT-AND-REFUSING, because that is the one that looked like a real
# failure. Nothing covered it until now.
#
# Driven through the CHARON_LIB_ONLY seam so run_unison_guarded is called
# directly: the interesting states are the inhibitor's exit code crossed with
# unison's, and reaching those through a full sync pass would need the gate,
# the lock and a live source to cooperate first.
. "$(dirname "$0")/lib.sh"
harness_init inhibitor

export CHARON_LIBEXEC=$HERE/libexec
export CHARON_LIB_ONLY=1
export HOME=$T
export CHARON_CONFIG=$T/cfg
export UNISON_DIR=$T/uni
mkdir -p "$T/cfg/profiles.d" "$T/bin" "$T/uni"

# shellcheck disable=SC1090
. "$CHARON_LIBEXEC/charon-sync"

PATH="$T/bin:$PATH"

# systemd-inhibit: PRESENT, and its verdict is ours to set. It records whether
# it was asked to probe or to wrap a real run, so we can prove which path ran.
_inhibit() {   # <probe-exit>
  cat > "$T/bin/systemd-inhibit" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in --why=*) echo "\${a#--why=}" >> "$T/inhibit.log" ;; esac
done
case " \$* " in
  *" true "*) exit $1 ;;            # the throwaway probe
esac
echo "WRAPPED" >> "$T/inhibit.log"  # a real run, held under the inhibitor
shift_to_cmd=
for a in "\$@"; do
  case "\$a" in --*) ;; *) shift_to_cmd=y ;; esac
  [ -n "\$shift_to_cmd" ] && break
done
# run whatever followed the flags, so unison's status still propagates
for a in "\$@"; do case "\$a" in --*) shift ;; *) break ;; esac; done
exec "\$@"
EOF
  chmod +x "$T/bin/systemd-inhibit"
}

# unison: exits with whatever we ask, and records that it ran AT ALL. "did
# unison run" is the whole question for a degraded pass.
_unison() {   # <exit>
  printf '#!/bin/sh\necho RAN >> "%s"\nexit %s\n' "$T/unison.log" "$1" \
    > "$T/bin/unison"
  chmod +x "$T/bin/unison"
}
printf '#!/bin/sh\nshift 2\nexec "$@"\n' > "$T/bin/timeout"
chmod +x "$T/bin/timeout"

_reset() { : > "$T/inhibit.log"; : > "$T/unison.log"; }
_ran()   { grep -qx RAN "$T/unison.log"; }

# --- DENIED + unison succeeds: the pass must SUCCEED, not inherit polkit's 1 ---
# The regression that mattered. A denial exiting 1 made the whole pass look
# like a unison failure, so it raised a fault and a notify flag for a condition
# that is not an error at all.
_reset; _inhibit 1; _unison 0
out=$(run_unison_guarded testprof 2>&1); rc=$?
_ran || fail "a DENIED inhibitor stopped unison from running at all"
[ "$rc" = 0 ] \
  || fail "denied inhibitor + successful unison exited $rc; polkit's refusal
    must not become the pass's verdict"
printf '%s\n' "$out" | grep -qi 'unprotected' \
  || fail "the degrade was SILENT; it must warn that sleep is unprotected"
grep -qx WRAPPED "$T/inhibit.log" \
  && fail "unison was run UNDER an inhibitor that had already refused" || :

# --- DENIED + unison fails: the status must be UNISON's, and preserved ---
# 'a real non-zero is always unison's, never polkit's' is only half proven by
# the case above; a non-zero has to survive the degraded path too, or a genuine
# failure would be swallowed.
_reset; _inhibit 1; _unison 3
run_unison_guarded testprof >/dev/null 2>&1; rc=$?
_ran || fail "unison did not run on the degraded path"
[ "$rc" = 3 ] || fail "unison's exit 3 became $rc on the degraded path"

# --- GRANTED: unison runs UNDER the inhibitor, and still reports its own rc ---
_reset; _inhibit 0; _unison 0
run_unison_guarded testprof >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] || fail "granted inhibitor + good unison exited $rc"
_ran || fail "unison did not run under a GRANTED inhibitor"
grep -qx WRAPPED "$T/inhibit.log" \
  || fail "the inhibitor was granted but unison ran OUTSIDE it, so a suspend
    mid-pass can still wedge on the FUSE mount"

_reset; _inhibit 0; _unison 4
run_unison_guarded testprof >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] || fail "unison's exit 4 became $rc under a granted inhibitor"

# --- the PROBE must be a throwaway, never the real command ---
# It exists so a real non-zero is always unison's. If the probe ever wrapped
# the actual run, a denial would be indistinguishable from a sync failure --
# which is precisely the bug this whole file is about.
_reset; _inhibit 0; _unison 0
run_unison_guarded testprof >/dev/null 2>&1
grep -qi 'probe' "$T/inhibit.log" \
  || fail "no throwaway probe was attempted before the real run"

# --- ABSENT is still the degrade path (skip.t's case, pinned here too) ---
# REMOVING THE STUB IS NOT ENOUGH, and this project has recorded that trap once
# already for systemctl: /usr/bin/systemd-inhibit stays on PATH, so the first
# version of this case invoked the REAL one, which a SEATED session GRANTS. It
# passed while testing the exact opposite of what it claimed. So: restrict PATH
# to the stub dir, and ASSERT THE HARNESS IS HONEST before asserting anything
# about charon.
_reset; rm -f "$T/bin/systemd-inhibit"; _unison 0
# MIRROR the system bins MINUS systemd-inhibit. Emptying PATH instead would
# "pass" for the wrong reason: the case would die on a missing grep before it
# ever reached charon.
mkdir -p "$T/sysbin"
for _t in grep cat sed head printf ls rm env sh; do
  _p=$(command -v "$_t" 2>/dev/null) && ln -sfn "$_p" "$T/sysbin/$_t"
done
( PATH="$T/bin:$T/sysbin"; export PATH
  command -v systemd-inhibit >/dev/null 2>&1 \
    && { echo "HARNESS-DISHONEST"; exit 9; }
  out=$(run_unison_guarded testprof 2>&1); rc=$?
  _ran || { echo "an ABSENT inhibitor stopped unison from running"; exit 1; }
  [ "$rc" = 0 ] || { echo "absent inhibitor + good unison exited $rc"; exit 1; }
  printf '%s\n' "$out" | grep -qi 'unprotected' \
    || { echo "an absent inhibitor degraded silently"; exit 1; }
) >"$T/absent.out" 2>&1 || {
  grep -q HARNESS-DISHONEST "$T/absent.out" \
    && fail "the harness never removed systemd-inhibit from PATH, so this case
      was testing the REAL one (which a seated session grants)"
  fail "absent-inhibitor case: $(cat "$T/absent.out")"
}

pass "a denied or absent inhibitor degrades the pass and keeps unison's status"
