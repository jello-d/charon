#!/bin/sh
# setup.t - the install roundtrip against a scratch PREFIX, for the PAYLOAD
# layout: install -> assert a self-contained tree with links into it ->
# check (green, then once per way of breaking it) -> bootstrap -> uninstall.
#
# THE CENTRAL CLAIM IS NOT "the files are there", it is that the install does
# not depend on this source tree. The old layout satisfied every presence
# assertion while symlinking ~/.local straight at the repo, so part 2 proves it
# the only way that cannot be faked: install from a COPY, DELETE the copy, and
# run the command.
#
# EVERY INVOCATION GETS A FAKE HOME, not only the cases that are about HOME.
# A conversion's whole job is editing the code that computes install paths, so
# the sandbox must not depend on that code being correct: the fleet's recipe
# records a sibling package losing its live venv twice, the second time to the
# regression harness that was proving the guard worked.
. "$(dirname "$0")/harness_lib"
harness_init setup

PREFIX=$T/local
XDG_BIN_HOME=$PREFIX/bin
XDG_DATA_HOME=$PREFIX/share
XDG_CONFIG_HOME=$T/config
HOME=$T/home
mkdir -p "$HOME"
export PREFIX XDG_BIN_HOME XDG_DATA_HOME XDG_CONFIG_HOME HOME
PAY=$XDG_DATA_HOME/charon

# The sandbox is only honest if HOME really is fake, so say so out loud rather
# than trusting the export above.
case $HOME in "$T"/*) ;; *) fail "HOME is not inside the scratch dir" ;; esac

_setup() { sh "$HERE/setup.sh" "$@"; }

# ------------------------------------------------------------------ part 1 ---
# THE PAYLOAD IS A REAL TREE, and the links point INTO it.
_setup install >/dev/null || fail "install errored"

[ -d "$PAY" ] || fail "no payload tree at $PAY"
[ -L "$PAY" ] && fail "the payload is a SYMLINK, which is the old layout" || :
# bin, libexec and share must be SIBLINGS inside it: an installed charon
# resolves its own real path and reads ../libexec and ../share/charon from
# there, so this nesting is the load-bearing part of the layout.
for _f in bin/charon libexec/charon-sync libexec/charon-mount \
          libexec/charon-source lib/common_lib \
          share/charon/example.conf share/charon/example-source.conf \
          share/charon/example-charon.conf man/man1/charon.1; do
  [ -f "$PAY/$_f" ] || fail "payload is missing $_f"
  [ -L "$PAY/$_f" ] && fail "payload's $_f is a LINK, not a copy" || :
done

for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t"); _l=$XDG_BIN_HOME/$_n
  [ -L "$_l" ] || fail "$_n is not a symlink in PREFIX/bin"
  [ "$(readlink "$_l")" = "$PAY/bin/$_n" ] \
    || fail "$_n links to $(readlink "$_l"), not into the payload"
done
_ml=$(readlink "$XDG_DATA_HOME/man/man1/charon.1")
[ "$_ml" = "$PAY/man/man1/charon.1" ] \
  || fail "the man page links to $_ml, not into the payload"

# THE INVARIANT, stated as the absence it is: nothing under the prefix may
# resolve back into the source tree. This is the one assertion the old layout
# could not have passed.
_stray=$(find "$PREFIX" -type l 2>/dev/null | while IFS= read -r _l; do
  case "$(readlink -m -- "$_l" 2>/dev/null)" in
    "$HERE"|"$HERE"/*) printf '%s\n' "$_l" ;;
  esac; done)
[ -z "$_stray" ] || fail "links under PREFIX resolve into the source tree:
  $_stray"
# And NO top-level libexec root: that prefix is struck by the placement rule.
[ -e "$PREFIX/libexec/charon" ] \
  && fail "install created the retired ~/.local/libexec/charon" || :

# Re-running is a no-op, and leaves no staging directory behind.
_setup install >/dev/null || fail "a second install errored"
[ -z "$(find "$XDG_DATA_HOME" -maxdepth 1 -name 'charon.new' \
        -o -maxdepth 1 -name 'charon.old' 2>/dev/null)" ] \
  || fail "install left a staging directory behind"

# ------------------------------------------------------------------ part 2 ---
# THE PROOF: install from a copy, DELETE the copy, run the command. This is
# what the conversion exists for. An integrator clones charon into a cache it
# re-clones on every sweep and wipes on demand, so under the old layout the
# command stopped existing at that moment, with nothing able to diagnose it
# because charon was the thing that had gone.
SRC=$T/src
mkdir -p "$SRC"
cp "$HERE/setup.sh" "$SRC/"
for _d in bin lib libexec share man; do cp -R "$HERE/$_d" "$SRC/"; done
rm -rf -- "$PREFIX"
sh "$SRC/setup.sh" install >/dev/null || fail "install from the copy errored"
rm -rf -- "$SRC"
[ -d "$SRC" ] && fail "the source copy survived the rm; the test is void" || :

"$XDG_BIN_HOME/charon" --help >"$T/help.out" 2>&1 \
  || fail "the installed charon does not RUN with its source tree deleted:
  $(cat "$T/help.out")"
grep -q 'usage: charon' "$T/help.out" \
  || fail "charon --help printed no usage: $(cat "$T/help.out")"
# A verb that reaches into libexec, so the self-location is exercised and not
# just the dispatcher's own usage text.
"$XDG_BIN_HOME/charon" source list >/dev/null 2>&1 \
  || fail "charon source list failed with the source tree deleted; the impls
  in libexec are not being found inside the payload"
# ...and one that reads share/, the third sibling.
grep -q 'share/charon/example.conf' "$PAY/libexec/charon-sync" \
  && [ -f "$PAY/share/charon/example.conf" ] \
  || fail "the payload's share/charon is not where charon-sync looks for it"

# Put a normal install back for the rest of the file.
rm -rf -- "$PREFIX"
_setup install >/dev/null || fail "reinstall from the repo errored"

# ------------------------------------------------------------------ part 3 ---
# check reports the tools (put the sandbox bin FIRST so command -v resolves it)
_chk() { PATH="${1:-$XDG_BIN_HOME:$PATH}" sh "$HERE/setup.sh" check \
           >"$T/c.out" 2>&1; }
_chk || fail "check is not green on a fresh install: $(cat "$T/c.out")"
grep -q '\[OK\].*charon present' "$T/c.out" \
  || fail "check did not report the linked command"
grep -q '\[OK\].*payload is a self-contained tree' "$T/c.out" \
  || fail "check did not report the payload"

# --- and it must FAIL on a BROKEN install, which nothing asserted until now ---
# A check only ever run against a healthy tree proves nothing: this one exited
# 0 on every breakage below until 2026-09-16, because `command -v <name>` was
# satisfied by ANY copy on PATH.
#
# Each case below is a MUTATION of the installed state, and each must be named
# in the output: an assertion on the process-wide exit code cannot tell you
# which of ten things failed, and a dozen causes can set it.
_broken() {   # <what was broken> <pattern check must print>
  _chk && fail "check PASSED with $1"
  grep -qi "$2" "$T/c.out" \
    || fail "check did not name the problem for $1; it printed:
  $(cat "$T/c.out")"
}

# SHADOWED: a different charon earlier on PATH. The conventions ban two copies
# on PATH precisely because the stale one wins and then rots unnoticed, so the
# check has to assert WHICH copy resolves, not merely that one does.
mkdir -p "$T/shadow"
printf '#!/bin/sh\nexit 0\n' > "$T/shadow/charon"; chmod +x "$T/shadow/charon"
PATH="$T/shadow:$XDG_BIN_HOME:$PATH" sh "$HERE/setup.sh" check \
  >"$T/c.out" 2>&1 && fail "check passed while a DIFFERENT charon shadowed it"
grep -qi 'shadow' "$T/c.out" \
  || fail "check did not explain that the command was shadowed"
rm -rf "$T/shadow"

# MISSING: the installed command deleted out from under it.
mv "$XDG_BIN_HOME/charon" "$T/charon.parked"
_broken "the command uninstalled" 'not installed'
mv "$T/charon.parked" "$XDG_BIN_HOME/charon"

# DANGLING: the symlink survives but its target does not.
ln -sfn /nonexistent/charon "$XDG_BIN_HOME/charon"
_broken "a DANGLING symlink" 'charon'
_setup install >/dev/null || fail "reinstall after breakage failed"
_chk || fail "check did not go green again after repair"

# THE OLD LAYOUT RESTORED: the payload replaced by a link at the source tree.
# This is the regression the conversion exists to prevent, so it is the one
# case that must never pass.
rm -rf -- "$PAY"
ln -sfn "$HERE/share/charon" "$PAY"
_broken "the payload replaced by a symlink into the source" 'SYMLINK'
rm -f "$PAY"; _setup install >/dev/null

# PAYLOAD GONE: the cache-wipe shape, now survivable but still reportable.
mv "$PAY" "$T/pay.parked"
_broken "the payload removed" 'no payload tree'
mv "$T/pay.parked" "$PAY"

# A PAYLOAD FILE hollowed out into a link back at the source. The tree looks
# complete to `ls` and dies on the next re-clone.
#
# THE PATTERN IS THE MESSAGE, NOT THE FILENAME, and the difference is not
# pedantry: with 'common_lib' this case passed with the per-file check REMOVED,
# because the stray-link walk prints the offending PATH and that path contains
# the filename. So the assertion was being satisfied by a different finding.
# Found by mutation; it is the "grep for the project's own wording" rule one
# level in, where two of charon's own checks can answer for each other.
rm -f "$PAY/lib/common_lib"
ln -sfn "$HERE/lib/common_lib" "$PAY/lib/common_lib"
_broken "a payload file that is a link into the source" \
        'payload is missing lib/common_lib'
# AND THE REPAIR IS ASSERTED HERE, not left to a later case, because this is
# the state that catches a stage which FILLS the payload in place instead of
# replacing it: `cp` over a symlink FOLLOWS it and writes THROUGH into the
# source, so the hollow file stays hollow and install reports success.
_setup install >/dev/null
_chk || fail "check is not green after reinstalling over a hollowed payload;
  a stage that copies INTO the live payload writes through its links instead
  of replacing them: $(cat "$T/c.out")"
[ -L "$PAY/lib/common_lib" ] \
  && fail "reinstall left the payload's common_lib a symlink" || :

# THE BIN LINK REPOINTED at the source: each half is asserted separately,
# because the payload can be perfect while the thing on PATH ignores it.
ln -sfn "$HERE/bin/charon" "$XDG_BIN_HOME/charon"
_broken "bin/charon pointing at the source tree" 'does not link to'
_setup install >/dev/null

# THE MAN LINK REPOINTED at the source. Asserted separately from the bin link
# for the same reason the two are written separately: a loop that checked only
# one of them read as checking both, and the man page is the half nobody
# notices is broken until `man charon` says nothing.
ln -sfn "$HERE/man/man1/charon.1" "$XDG_DATA_HOME/man/man1/charon.1"
_broken "the man link pointing at the source tree" \
        'man/man1/charon.1 does not link to'
_setup install >/dev/null

# A STRAY LINK somewhere nobody would think to look. The broad walk is the
# whole reason check asks about the prefix rather than only re-reading the
# paths install just wrote.
mkdir -p "$XDG_DATA_HOME/applications"
ln -sfn "$HERE/share/charon/example.conf" \
        "$XDG_DATA_HOME/applications/charon-leftover"
_broken "a stray link into the source in an unexpected place" 'resolve into'
rm -f "$XDG_DATA_HOME/applications/charon-leftover"

# THE RETIRED ROOT: a WARN rather than a FAIL (it is stale, not broken), and
# the next install must remove it. Driven BOTH ways, because a retire nothing
# proves is a decision recorded only in prose.
mkdir -p "$PREFIX/libexec"
ln -sfn "$HERE/libexec" "$PREFIX/libexec/charon"
_chk && fail "check passed with a link into the source at the retired root"
grep -q '\[WARN\].*retired layout path survives' "$T/c.out" \
  || fail "check did not report the surviving retired layout path:
  $(cat "$T/c.out")"
_setup install >/dev/null || fail "install errored over the retired root"
[ -e "$PREFIX/libexec/charon" ] || [ -L "$PREFIX/libexec/charon" ] \
  && fail "install did not retire $PREFIX/libexec/charon" || :
_chk || fail "check is not green after the retire: $(cat "$T/c.out")"

# THE `rm -rf` SHAPE GUARD, proved rather than trusted. _payload_stage removes
# directories, so it refuses a payload path that is not plainly absolute and
# nested: the standing fleet rule is that `rm -rf` never runs on an unexamined
# variable, and the reason it is a HARD rule is that a sibling project's
# harness deleted its own working tree when one resolved empty.
#
# DRIVEN WITH A RELATIVE PREFIX, which is the honest way in: the guard reads
# $_pay, and a relative PREFIX is the ordinary mistake that produces a $_pay no
# `rm -rf` should ever see. Run from a scratch cwd so a stage that went ahead
# anyway would land in the sandbox, not the repo.
mkdir -p "$T/relcwd"
( cd "$T/relcwd" \
    && PREFIX=rel XDG_BIN_HOME= XDG_DATA_HOME= sh "$HERE/setup.sh" install \
         >"$T/rel.out" 2>&1 ) \
  && fail "install accepted a relative PREFIX, so the payload path reaching
  \`rm -rf\` was never checked: $(cat "$T/rel.out")"
grep -q 'refusing to stage a payload' "$T/rel.out" \
  || fail "install failed on a relative PREFIX for some OTHER reason, so the
  shape guard is not what stopped it: $(cat "$T/rel.out")"
[ -e "$T/relcwd/rel" ] \
  && fail "install staged a payload under a relative PREFIX anyway" || :

# ------------------------------------------------------------------ part 4 ---
# MIGRATION FROM THE PRE-CONVERSION LAYOUT, in ONE install, which is what
# every deployed box will do. All four of the old links are present at once;
# the payload path is one of them, so the stage must not write THROUGH it.
rm -rf -- "$PREFIX"
mkdir -p "$XDG_BIN_HOME" "$PREFIX/libexec" "$XDG_DATA_HOME/man/man1"
ln -sfn "$HERE/bin/charon" "$XDG_BIN_HOME/charon"
ln -sfn "$HERE/libexec" "$PREFIX/libexec/charon"
ln -sfn "$HERE/share/charon" "$PAY"
ln -sfn "$HERE/man/man1/charon.1" "$XDG_DATA_HOME/man/man1/charon.1"
_setup install >/dev/null || fail "install over the old layout errored"
[ -d "$PAY" ] && [ ! -L "$PAY" ] \
  || fail "install over the old layout left a symlink at the payload path"
_chk || fail "check is not green after migrating from the old layout:
  $(cat "$T/c.out")"
# The source tree must come through it untouched: the old payload path was a
# link INTO it, so a `cp` that followed that link would have written into the
# repo this test is running from.
for _f in share/charon/example.conf lib/common_lib bin/charon; do
  [ -f "$HERE/$_f" ] || fail "the migration damaged the source tree ($_f)"
done
[ -e "$HERE/share/charon/bin" ] \
  && fail "the migration wrote THROUGH the old share link into the source" || :

# ------------------------------------------------------------------ part 5 ---
# --- THE BUILD STAMP: a fleet must be able to compare two nodes --------------
# `VERSION=0.1.0` is hand-set and had not moved across any release, so on
# 2026-10-04 three nodes running three different commits all reported `charon
# 0.1.0`. That is not cosmetic with a shared remote: the conflict-twin fix is
# fleet-wide or nothing, because one node still uploading twins re-pollutes the
# remote for every other node, and nothing on any box could have said a peer was
# behind.
_bf=$PREFIX/share/charon/share/charon/BUILD
[ -f "$_bf" ] || fail "install did not stamp a build id at $_bf"
_stamp=$(head -1 "$_bf")
[ -n "$_stamp" ] || fail "the build stamp is empty"
# This repo IS a git checkout, so the stamp must name a commit, not 'unknown'.
_re='^[0-9a-f]{7,}(-dirty)? [0-9]{4}-[0-9]{2}-[0-9]{2}$'
printf '%s\n' "$_stamp" | grep -qE "$_re" \
  || fail "the build stamp is not <short-sha>[-dirty] <date>: '$_stamp'"

# the installed command must report it, with neither git nor a source tree
_cv=$(PATH="$XDG_BIN_HOME:$PATH" charon --version 2>&1)
printf '%s\n' "$_cv" | grep -qF "$_stamp" \
  || fail "charon --version does not report the stamped build: got '$_cv',
    stamp is '$_stamp'"
for _v in version -V; do
  PATH="$XDG_BIN_HOME:$PATH" charon "$_v" 2>&1 | grep -qF "$_stamp" \
    || fail "'charon $_v' does not report the build stamp"
done

# AN UNSTAMPED TREE MUST SAY SO, not invent a version: a fabricated answer is
# worse than no answer when the whole point is comparing two nodes.
_un=$T/unstamped
mkdir -p "$_un/bin" "$_un/share/charon" "$_un/lib"
cp "$HERE/bin/charon" "$_un/bin/charon"
_uv=$(sh "$_un/bin/charon" --version 2>&1)
printf '%s\n' "$_uv" | grep -qi 'UNSTAMPED' \
  || fail "a payload with no BUILD file did not say UNSTAMPED: '$_uv'"
printf '%s\n' "$_uv" | grep -qE '[0-9a-f]{7,} [0-9]{4}-' \
  && fail "an unstamped payload invented a build id: '$_uv'" || :

# A DIRTY CHECKOUT IS NOT THE COMMIT IT CLAIMS. Two nodes installed from the
# same sha, one from an edited tree, are NOT running the same code, and a stamp
# that hid that would make the comparison lie.
_dirty=$T/dirtysrc
cp -R "$HERE" "$_dirty" 2>/dev/null || :
if [ -d "$_dirty/.git" ]; then
  printf '\n# scratch edit\n' >> "$_dirty/README.md"
  _ds=$(cd "$_dirty" && sh setup.sh version 2>&1)
  printf '%s\n' "$_ds" | grep -q 'dirty' \
    || fail "an EDITED checkout reported a clean build id: '$_ds'"
fi

# bootstrap seeds the example into an empty profiles.d, and is a no-op once full
_setup bootstrap >/dev/null || fail "bootstrap errored"
[ -f "$XDG_CONFIG_HOME/charon/profiles.d/example.conf" ] \
  || fail "bootstrap did not seed the example profile"
grep -q '^SOURCE=' "$XDG_CONFIG_HOME/charon/profiles.d/example.conf" \
  || fail "seeded example does not name a SOURCE"
printf 'SUBTREE=Keep\n' > "$XDG_CONFIG_HOME/charon/profiles.d/mine.conf"
_setup bootstrap >/dev/null || fail "second bootstrap errored"
grep -q '^SUBTREE=Keep' "$XDG_CONFIG_HOME/charon/profiles.d/mine.conf" \
  || fail "bootstrap clobbered an existing profile"

# ------------------------------------------------------------------ part 6 ---
# uninstall removes the links AND the payload, and NOTHING else. The config is
# deliberately not its business: the cache and the profiles outlive it.
_setup uninstall >/dev/null || fail "uninstall errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  { [ -e "$XDG_BIN_HOME/$_n" ] || [ -L "$XDG_BIN_HOME/$_n" ]; } \
    && fail "$_n still present after uninstall" || :
done
[ -e "$PAY" ] || [ -L "$PAY" ] && fail "the payload survived uninstall" || :
{ [ -e "$XDG_DATA_HOME/man/man1/charon.1" ] \
  || [ -L "$XDG_DATA_HOME/man/man1/charon.1" ]; } \
  && fail "the man link survived uninstall" || :
[ -f "$XDG_CONFIG_HOME/charon/profiles.d/mine.conf" ] \
  || fail "uninstall removed a profile, which it does not own"

# AND FROM THE PRE-CONVERSION LAYOUT TOO, because a box uninstalling without
# having reinstalled first still carries links at the source tree, and leaving
# one behind leaves a dangling `charon` on PATH: the exact failure this whole
# change is about.
mkdir -p "$XDG_BIN_HOME" "$PREFIX/libexec" "$XDG_DATA_HOME/man/man1"
ln -sfn "$HERE/bin/charon" "$XDG_BIN_HOME/charon"
ln -sfn "$HERE/libexec" "$PREFIX/libexec/charon"
ln -sfn "$HERE/share/charon" "$PAY"
ln -sfn "$HERE/man/man1/charon.1" "$XDG_DATA_HOME/man/man1/charon.1"
_setup uninstall >/dev/null || fail "uninstall over the old layout errored"
_left=$(find "$PREFIX" -type l 2>/dev/null | while IFS= read -r _l; do
  case "$(readlink -m -- "$_l" 2>/dev/null)" in
    "$HERE"|"$HERE"/*) printf '%s\n' "$_l" ;;
  esac; done)
[ -z "$_left" ] || fail "uninstall left links at the source tree:
  $_left"
[ -f "$HERE/share/charon/example.conf" ] \
  || fail "uninstall followed the old share link and deleted the source"

# THE SANDBOX HELD. Checked rather than assumed, because the fleet's own
# recipe records a regression harness that reached the real HOME while looking
# fully sandboxed, twice.
[ -d "$T/home" ] || fail "the fake HOME vanished during the run"
[ ! -e "$T/home/.local/share/charon" ] \
  || fail "something installed into the fake HOME's own .local, so a real run
  would have written outside the prefix it was given"

pass "the payload survives its source deleted; roundtrip + 11 breakages"
