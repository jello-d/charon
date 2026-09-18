#!/bin/sh
# prereq.t - install must demand privilege ONLY when it genuinely needs it.
#
# THE DEFECT THIS PINS (found 2026-09-17). charon needs exactly one privileged
# thing: apt-installing unison when it is ABSENT. A sudo gate was added for
# that, because demanding privilege unconditionally made `charon install`
# unrunnable from any non-TTY context -- an agent shell, a non-interactive ssh,
# a unit -- on a box that needed none, and turned every routine prf
# regeneration into a sudo handoff.
#
# But the gate asked `dpkg -l | grep '^ii  unison '`, which is not the question.
# The need is that unison is RUNNABLE. A unison built from source, or from nix
# or brew, or in /usr/local/bin, is invisible to dpkg -- so charon called it
# absent, demanded sudo it did not need, and exited 3. The false prerequisite
# was removed for the apt case and left in place for everybody else.
#
# Measured before the fix: unison on PATH and runnable, install exit 3.
. "$(dirname "$0")/lib.sh"
harness_init prereq

export HOME=$T
CFG=$T/cfg
mkdir -p "$T/bin" "$CFG/profiles.d" "$CFG/sources.d" "$T/mnt/Docs" \
         "$T/cache/Docs" "$T/st"
echo data > "$T/mnt/Docs/f.txt"; echo data > "$T/cache/Docs/f.txt"
cat > "$CFG/sources.d/s.conf" <<EOF
PROVIDER=none
MOUNT=$T/mnt
CACHE_ROOT=$T/cache
EOF
printf 'SOURCE=s:Docs\n' > "$CFG/profiles.d/docs.conf"
for s in systemctl systemd-run mountpoint; do
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
# Pre-seed traits so install does not probe: the probe is not under test here.
cat > "$T/st/s" <<EOF
PROBED=2026-09-17T00:00:00+00:00
CASE=sensitive
TIMES=settable
PERMS=posix
LINKS=yes
FSTYPE=ext4
MOUNTPOINT=no
EOF

# sudo that REFUSES, exactly as in a non-TTY context. Any install that reaches
# for privilege therefore fails loudly instead of silently succeeding here.
cat > "$T/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo: a terminal is required to authenticate" >&2
exit 1
EOF
chmod +x "$T/bin/sudo"

_c() {
  PATH="$T/bin:/usr/bin:/bin" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg sh "$HERE/bin/charon" "$@"
}

# --- unison RUNNABLE but NOT a dpkg package: needs NO privilege ---
# The regression. dpkg exists and answers honestly about a box where unison was
# built from source: it knows nothing about it.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/unison"; chmod +x "$T/bin/unison"
printf '#!/bin/sh\necho "ii  coreutils  9.1"\n' > "$T/bin/dpkg"
chmod +x "$T/bin/dpkg"
out=$(_c install 2>&1); rc=$?
[ "$rc" = 0 ] || fail "install exited $rc with a RUNNABLE unison that dpkg does
  not know about; it reached for sudo it does not need ($out)"
[ -f "$T/uni/charon-docs.prf" ] || fail "install generated no prf"

# --- no dpkg AT ALL (not a Debian box): still needs no privilege ---
rm -f "$T/bin/dpkg"
rm -rf "$T/uni" "$T/xdg"
out=$(_c install 2>&1); rc=$?
[ "$rc" = 0 ] || fail "install exited $rc on a box with no dpkg but a working
  unison ($out)"
[ -f "$T/uni/charon-docs.prf" ] || fail "install generated no prf without dpkg"

# --- unison GENUINELY absent: privilege IS the right answer, so it must fail
# --- loudly here rather than pretend it installed something.
#
# REMOVING THE STUB IS NOT ENOUGH: this box HAS a real /usr/bin/unison (that is
# how behaviour.t runs), so deleting $T/bin/unison leaves it perfectly
# reachable. The first version of this case did exactly that and "passed" while
# unison was present the whole time -- the THIRD time this trap caught me in one
# session, which is why path_without exists and asserts its own honesty.
rm -f "$T/bin/unison"
rm -rf "$T/uni" "$T/xdg"
_nou=$(path_without unison apt-get) || exit 1
[ -L "$_nou/unison" ] || [ -e "$_nou/unison" ] \
  && fail "the mirrored PATH still reaches unison, so the absent case below
    is not testing absence at all"
_noc() {
  PATH="$T/bin:$_nou" CHARON_CONFIG=$CFG CHARON_TRAITS_DIR=$T/st \
    UNISON_DIR=$T/uni XDG_CONFIG_HOME=$T/xdg sh "$HERE/bin/charon" "$@"
}
out=$(_noc sync install 2>&1); rc=$?
[ "$rc" = 0 ] \
  && fail "install claimed success with NO unison and NO privilege ($out)" || :
printf '%s\n' "$out" | grep -qi 'privilege\|sudo' \
  || fail "the refusal did not say privilege was the problem ($out)"

# --- absent unison AND no apt: say THAT, rather than run a missing apt-get ---
# charon knows one installer. Reporting the real situation beats dying inside a
# `sudo apt-get` that does not exist. Reached by letting sudo SUCCEED, so the
# privilege gate passes and install_packages is what must explain itself.
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
out=$(_noc sync install 2>&1) || :
printf '%s\n' "$out" | grep -qi 'apt-get is not available' \
  || fail "with no unison and no apt-get, charon did not explain itself ($out)"

pass "install demands privilege only when unison is genuinely absent"
