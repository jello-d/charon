# charon

Remote-storage mount + bidirectional sync over rclone. charon ferries files
between **any** rclone remote (Google Drive, Dropbox, …) and the local machine:
it mounts the remote via FUSE and keeps a fast local cache in step with it using
Unison. The value is the *management* — a caching mount, bidirectional sync,
resumable seeding — not the provider.

Two tools on `PATH`; there is no eponymous `charon` command.

## Tools

- **charon-mount** — mount the rclone remote via FUSE at `~/<remote>` with
  feels-like-local VFS-cache flags, and manage its systemd `--user` unit.
  Backend-specific flags (e.g. Drive's `--drive-skip-gdocs`) apply only to the
  matching remote type.
- **charon-sync** — keep the local cache (`~/.<remote>`) in step with the mount
  using Unison (the mount is canonical), driven by per-subtree **profiles**.

## Install

    ./setup.sh install      # symlink tools (+ libexec/share/man) into ~/.local
    ./setup.sh bootstrap    # copy the example profile into an empty profiles.d
    ./setup.sh check        # tools + deps present; [OK]/[FAIL] markers
    ./setup.sh test         # the in-repo suite (also: sh test/run)

Honors `PREFIX` (default `~/.local`) and the `XDG_*` vars. Runtime deps:
`rclone` + `unison` (core), `fuse3` (`user_allow_other` for the mount).
rclone should come from upstream, not a distro package — a distro rclone is
often too old for current OAuth flows.

## Profiles (config, not baked in)

Each `~/.config/charon/profiles.d/<name>.conf` (KEY=VALUE, read literally)
defines one synced subtree:

    SUBTREE=Documents          # path under ~/<remote> + ~/.<remote> (required)
    LINK=~/Documents           # optional working dir -> the cache subtree
    INTERVAL=30m               # unison timer cadence (OnUnitActiveSec)
    BOOT=10m                   # timer OnBootSec
    JITTER=2m                  # timer RandomizedDelaySec
    #SEED_PRIORITY=Docs/now    # subtree seeded synchronously at install
    SEED_FULL_ORDER=10         # join the background full seed, ascending

`charon-sync install` generates a Unison profile + a systemd timer per config,
lays the working links, seeds the priority subtrees synchronously, then
bulk-seeds the full tree in the background. Ships `share/charon/example.conf`;
`setup.sh bootstrap` copies it into an empty `profiles.d`.

## Configuration seams

- **`CHARON_REMOTE`** — the rclone remote name (default `gdrive`); the mount
  (`~/$CHARON_REMOTE`) and cache (`~/.$CHARON_REMOTE`) derive from it, so one
  override renames all three. `CHARON_MOUNT`/`CHARON_CACHE` override the paths.
- **`CHARON_RCLONE_PEER`** — an SSH host to copy the rclone remote stanza from
  (first-machine bootstrap; OAuth tokens are portable).
- **`CHARON_NOTIFY`** — an optional fault-notify command (`flag`/`clear`/`list`)
  charon calls on sync faults; empty = no notify. An integrator (e.g. a
  provisioning layer such as tackup) points it at its own notifier and supplies
  the profile files.

## License

Apache-2.0.
