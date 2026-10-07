# Offsite replication to r2d2 — gir iss `restore-offsite-replication` (8933937)
# and `retention-for-ungoverned-datasets` (270defa), map `5c80d58` (Offsite
# backup).
#
# Until the NixOS cutover this was `~/.local/bin/remotebackup`, a cron entry on
# myers' Ubuntu crontab. The cutover dropped the crontab, so nothing ran after
# the night of 2026-09-19/20. Ticket 01 decision 1: declarative here, as
# `services.syncoid`, so the job cannot vanish with a crontab again.
#
# What runs, nightly (ticket 01, as revised with the user on 2026-10-07):
#
#   push  bank10/vital          -> r2d2 mmm/backups/gir/vital
#   push  rpool/srv/postgresql  -> r2d2 mmm/backups/gir/postgresql
#   push  rpool/srv/forgejo     -> r2d2 mmm/backups/gir/forgejo   (new)
#   push  bank10/srv/gitea      -> r2d2 mmm/backups/gir/gt        (new: gt's
#         repos. Ticket 01 dropped this dataset as dead; gt.monoloco.net has
#         lived on it since. r2d2's old mmm/backups/gir/gitea stays a 2022
#         archive, untouched. gt's database is in postgresql, pushed above.)
#   pull  r2d2 mmm/music        -> bank7/music/r2d2  (the one pull; 450k cap,
#         as the cron had it)
#
# Not here yet: the duplicity half of ticket 01 (the `lh` archive and the new
# host-secrets archive). It needs a GPG key escrowed in 1Password and the old
# passphrase moved into /etc/gir-secrets first, so the user chose to ship the
# ZFS half on its own.
#
# The 2026-10-07 restart is a full resend. r2d2 kept only each target's
# 09-20 00:00 daily, and gir's sanoid had since pruned it, so no common
# snapshot or bookmark was left (checked 2026-10-07). The user renames r2d2's
# old vital/postgresql out of the way (`-2026-09-20`), the first run sends
# fresh ones under the old names, and the old copies are destroyed once the new
# ones are complete. At the measured ~388 Mbit/s, vital (5.0 T) takes about
# 30 h; the timer does not start a unit that is still running.
#
# Retention (ticket 01 decision 4, ticket 02, ADR 0003 in ~/p/gir): pushes
# mirror gir's sanoid policy on r2d2 through `--delete-target-snapshots`, so
# `production`'s daily=5/monthly=3 in sanoid.nix also decides r2d2's history.
# Ticket 02 decision 2 staged the first flagged push behind a manual review of
# r2d2's old snapshots; the fresh targets have none to review, so the flag is
# on from the first run. The pull carries no delete flag: gir governs its copy
# with a prune-only sanoid entry (sanoid.nix), and r2d2's sanoid must never
# cover mmm/backups/gir/*.
#
# Credentials: r2d2's `remotebackup` account accepts myers' ~/.ssh/remotebackup
# and holds create,destroy,mount,receive,rollback on mmm/backups. The unit runs
# as the module's `syncoid` user inside a RootDirectory sandbox that sees /etc,
# /run, the store and its StateDirectory, so the key lives at
# /var/lib/syncoid/remotebackup (syncoid:syncoid 0600, copied in by hand: a
# private key never enters the store or git), and r2d2's host key is pinned in
# /etc/ssh/ssh_known_hosts below.
{ config, lib, ... }:

let
  r2d2 = "remotebackup@r2d2.monoloco.net";
  push = source: target: {
    inherit source;
    target = "${r2d2}:mmm/backups/gir/${target}";
  };
in
{
  # The ECDSA key myers@gir already trusts, re-read 2026-10-07 and checked by
  # fingerprint: SHA256:v+1GwIbMCPLQFEyL5jrY+bUvd8vbiAP1u2W+a9B0BWI.
  programs.ssh.knownHosts.r2d2 = {
    hostNames = [ "r2d2.monoloco.net" ];
    publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFQY2Bcu6tp3MjL7zsToMgzXVdxcrdNcQxpOa4bCgCS543ffGi+sdaidY1eGywBdvNakSQU68leh/BvAucI/iD8=";
  };

  services.syncoid = {
    enable = true;

    # Nightly (the module defaults to hourly). sanoid takes the dailies at
    # 00:00 and runs every 15 minutes, so 01:30 is well clear of it.
    interval = "*-*-* 01:30:00";

    sshKey = "/var/lib/syncoid/remotebackup";

    # sanoid owns every snapshot (--no-sync-snap, as the cron had it), so the
    # source needs no snapshot/destroy; the module's default grants both.
    localSourceAllow = [
      "bookmark"
      "hold"
      "send"
    ];

    commonArgs = [
      "--no-sync-snap"
      "--delete-target-snapshots"
    ];

    commands = {
      vital = push "bank10/vital" "vital";
      postgresql = push "rpool/srv/postgresql" "postgresql";
      forgejo = push "rpool/srv/forgejo" "forgejo";
      gt = push "bank10/srv/gitea" "gt";

      music = {
        source = "${r2d2}:mmm/music";
        target = "bank7/music/r2d2";
        # Not commonArgs: no --delete-target-snapshots on the pull (ticket 02
        # decision 1). The cap is the cron's, so the pull doesn't fill r2d2's
        # uplink.
        useCommonArgs = false;
        extraArgs = [
          "--no-sync-snap"
          "--source-bwlimit=450k"
        ];
        # Receive unmounted: a delegated (non-root) mount fails on Linux, and
        # the copy is only read back by hand.
        recvOptions = "u";
      };
    };
  };

  # Ticket 02 decision 3: every local syncoid source is a sanoid dataset on
  # the `production` template (else its snapshots freeze and the push stalls
  # silently), and every local target has a sanoid entry (else nothing prunes
  # what the pull brings in).
  assertions =
    let
      isLocal = d: !(lib.hasInfix ":" d);
      cmds = lib.attrValues config.services.syncoid.commands;
      sanoid = config.services.sanoid.datasets;
      sources = lib.filter isLocal (map (c: c.source) cmds);
      targets = lib.filter isLocal (map (c: c.target) cmds);
      ungovernedSources = lib.filter (
        d: !(sanoid ? ${d}) || sanoid.${d}.use_template != [ "production" ]
      ) sources;
      ungovernedTargets = lib.filter (d: !(sanoid ? ${d})) targets;
    in
    [
      {
        assertion = ungovernedSources == [ ];
        message =
          "syncoid.nix: these syncoid sources have no sanoid entry on the production template, "
          + "so their snapshots would freeze and the push stall: "
          + lib.concatStringsSep ", " ungovernedSources;
      }
      {
        assertion = ungovernedTargets == [ ];
        message =
          "syncoid.nix: these local syncoid targets have no sanoid entry, so nothing prunes them: "
          + lib.concatStringsSep ", " ungovernedTargets;
      }
    ];
}
