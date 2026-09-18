#!/bin/sh
# notify.t - the fault seam, exercised as BEHAVIOUR rather than as config.
#
# THE GAP THIS CLOSES. profiles.t asserts the notify seam is BAKED into the
# generated unit as an absolute path. That is the config half, and it is the
# half that was already tested. Nothing asserted that a fault actually CALLS
# the notifier, that a success CLEARS the flag, or that a configured-but-absent
# notifier says so.
#
# That distinction is this project's most expensive lesson twice over: "a test
# that asserts config is not a test of behaviour" (the prf looked perfect while
# unison refused it for weeks), and the notify seam's own production defect --
# manifestor had CHARON_NOTIFY=intervention-required baked correctly into its
# units while the command was not on the unit PATH, so EVERY sync failure
# vanished: no flag, no reason in the journal, for days. A test of the baked
# value would have passed throughout.
#
# Driven through the CHARON_LIB_ONLY seam, calling notify() and
# run_sync_profile() directly: reaching a FAULT through a full pass needs the
# gate, the lock and a live source to cooperate first, and what matters here is
# only what the seam is told.
. "$(dirname "$0")/lib.sh"
harness_init notify

export CHARON_LIBEXEC=$HERE/libexec
export CHARON_LIB_ONLY=1
export HOME=$T
export CHARON_CONFIG=$T/cfg
export UNISON_DIR=$T/uni
mkdir -p "$T/cfg/profiles.d" "$T/bin" "$T/uni"
PATH="$T/bin:$PATH"

# A notifier that RECORDS the contract it was called with: `flag <id> <msg>`
# and `clear <id>`. One line per call, so ordering is assertable too.
cat > "$T/bin/rec-notify" <<EOF
#!/bin/sh
echo "\$*" >> "$T/notify.log"
exit \${REC_NOTIFY_RC:-0}
EOF
chmod +x "$T/bin/rec-notify"

# shellcheck disable=SC1090
. "$CHARON_LIBEXEC/charon-sync"

_reset() { : > "$T/notify.log"; _notify_warned=; }
_calls() { cat "$T/notify.log" 2>/dev/null; }

# --- CONFIGURED and present: flag and clear reach the notifier verbatim ---
_reset; CHARON_NOTIFY=rec-notify
notify flag charon-docs-sync "the mount went away"
notify clear charon-docs-sync
printf '%s\n' "$(_calls)" \
  | grep -qx 'flag charon-docs-sync the mount went away' \
  || fail "flag did not reach the notifier verbatim (got: $(_calls))"
printf '%s\n' "$(_calls)" | grep -qx 'clear charon-docs-sync' \
  || fail "clear did not reach the notifier (got: $(_calls))"

# --- EMPTY is a silent no-op: no notify is a SUPPORTED configuration ---
# charon must run standalone with no integrator, so an unset seam is not drift
# and must not warn. If this ever starts warning, every default install nags.
_reset; CHARON_NOTIFY=
out=$(notify flag x "y" 2>&1)
[ -z "$(_calls)" ] || fail "an EMPTY seam still invoked something"
[ -z "$out" ] || fail "an empty (unconfigured) seam warned: $out"

# --- CONFIGURED BUT ABSENT is DRIFT, and must say so ONCE ---
# The production failure exactly: set, baked, and unresolvable. Silence here is
# how a fault reaches nobody.
_reset; CHARON_NOTIFY=no-such-notifier-anywhere
# CAPTURE TO FILES, not $( ): the once-only guard is a shell variable, and a
# command substitution runs in a SUBSHELL, so each capture would get a fresh
# copy and the warning would "repeat" no matter what charon does. The first
# version of this case failed for exactly that reason -- the harness broke the
# mechanism it was testing.
notify flag charon-docs-sync "a fault" 2>"$T/w1"
grep -qi 'not on PATH' "$T/w1" \
  || fail "a configured-but-ABSENT notifier was a silent no-op
    ($(cat "$T/w1"))"
# ...and only once, or every pass reprints it and the warning stops being read
notify flag charon-docs-sync "another fault" 2>"$T/w2"
[ -s "$T/w2" ] \
  && fail "the absent-notifier warning repeats every call: $(cat "$T/w2")" || :

# --- a notifier that FAILS must not break the pass ---
# The seam is someone else's command; its exit status is not charon's problem,
# and a broken notifier must not turn a healthy sync into a failure.
_reset; CHARON_NOTIFY=rec-notify
REC_NOTIFY_RC=7 notify flag charon-docs-sync "a fault"; rc=$?
[ "$rc" = 0 ] || fail "a failing notifier propagated exit $rc into charon"
[ -n "$(_calls)" ] || fail "the failing notifier was not actually called"

#### the BEHAVIOUR: does a real pass flag on failure and clear on success? ####
# This is the part no test reached. run_sync_profile decides, and the decision
# is the whole product of the seam.
printf 'SUBTREE=Docs\n' > "$T/cfg/profiles.d/docs.conf"
mkdir -p "$T/mnt/Docs" "$T/cache/Docs"
echo data > "$T/mnt/Docs/f.txt"; echo data > "$T/cache/Docs/f.txt"
mkdir -p "$T/cfg/sources.d"
cat > "$T/cfg/sources.d/default.conf" <<EOF
PROVIDER=none
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
printf '#!/bin/sh\nshift 2\nexec "$@"\n' > "$T/bin/timeout"
chmod +x "$T/bin/timeout"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/mountpoint"; chmod +x "$T/bin/mountpoint"
CHARON_NOTIFY=rec-notify

# unison SUCCEEDS -> the flag must be CLEARED, so a resolved fault stops nagging
_reset
printf '#!/bin/sh\nexit 0\n' > "$T/bin/unison"; chmod +x "$T/bin/unison"
run_sync_profile docs >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] || fail "a healthy pass exited $rc (notify test setup wrong?)"
_calls | grep -q '^clear ' \
  || fail "a SUCCESSFUL pass did not CLEAR the flag, so an old fault would
    keep nagging after it was fixed (calls: $(_calls))"
_calls | grep -q '^flag ' \
  && fail "a successful pass raised a FLAG (calls: $(_calls))" || :

# unison FAILS -> a flag must be raised, naming the profile's service
_reset
printf '#!/bin/sh\nexit 2\n' > "$T/bin/unison"; chmod +x "$T/bin/unison"
run_sync_profile docs >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] || fail "a failing unison gave charon exit $rc, expected 2"
_calls | grep -q '^flag .*docs' \
  || fail "a FAILED pass raised NO flag naming the profile (calls: $(_calls))"
_calls | grep -q '^clear ' \
  && fail "a failed pass CLEARED the flag (calls: $(_calls))" || :

# and the fault must be LOGGED too, not only notified: the old form logged only
# when NO notifier was configured, so a set-but-missing one swallowed the
# reason entirely and the journal showed a bare exit status.
_reset
out=$(run_sync_profile docs 2>&1) || :
# Match charon's OWN wording, not the word "failed": systemd-inhibit prints
# "timeout failed with exit status 2" about its child, so a grep for 'failed'
# passed with charon's log_error deleted outright. Mutation testing caught it.
printf '%s\n' "$out" | grep -q 'Run it interactively' \
  || fail "the fault was notified but never LOGGED by charon; with an
    unreachable notifier the reason would vanish entirely ($out)"

pass "the notify seam: flag, clear, absent-is-drift, and a failing notifier"
