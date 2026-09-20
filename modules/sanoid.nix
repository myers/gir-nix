# Ticket 24 — Sanoid, the local ZFS snapshot policy.
#
# Ticket 05 puts Sanoid in the day-one reliability set: it is what stands
# between a bad `rm` (or a bad NixOS boot) and losing state on a dataset that
# both OSes share. Ticket 07 §"Rules that go with the manifest" fixes the
# shape:
#
#   * Entries are NON-RECURSIVE and keyed by dataset name. Every dataset that
#     is to be snapshotted gets its own stanza. That is why this file is long
#     and flat rather than three recursive stanzas.
#   * Window A renames `rpool/USERDATA/{myers,root}_ebnmd1` to
#     `rpool/home/{myers,root}` **and renames the sanoid entries in the same
#     step**. If it doesn't, both homes silently stop being snapshotted. That
#     rename has already happened on the live host (confirmed 2026-09-19:
#     /etc/sanoid/sanoid.conf vs sanoid.conf.pre-windowA differ in exactly
#     those two section headers), so this file carries the NEW names only.
#   * `rpool/srv/crash` and `rpool/nixos/nix` are excluded — see the assertion
#     at the bottom, which makes the exclusion enforced rather than remembered.
#   * None of these datasets goes into the `remotebackup` push (ticket 07
#     item 11), `rpool/srv/secrets` least of all. **syncoid is not configured
#     in this file at all** and must not be: `remotebackup` stays a user cron
#     job on myers' crontab (ticket 05), untouched by the migration.
#
# Source of the templates and the pre-existing entries: /etc/sanoid/sanoid.conf
# on the live host, read 2026-09-19.
#
# Difference from Ubuntu worth knowing: Ubuntu runs sanoid as root from
# sanoid.timer. The NixOS module runs it as a DynamicUser and delegates
# `snapshot,mount,destroy` per dataset with `zfs allow` in ExecStartPre (and
# `zfs unallow` in ExecStopPost). Every dataset named below must therefore
# EXIST when the unit starts, or `zfs allow` fails and the whole run fails.
# All of them exist on the live host today except `rpool/nixos/{root,log}`,
# which the NixOS install creates before this unit can ever run.
{ config, lib, ... }:

let
  # The one template Ubuntu defines, verbatim: 5 daily, 3 monthly, nothing
  # else. Deliberately not "improved" during the port — a retention change
  # during a migration is a change you cannot attribute later.
  production = [ "production" ];
in
{
  services.sanoid = {
    enable = true;

    # Ubuntu's sanoid.timer is `OnCalendar=*:0/15` (and there is an inert
    # /etc/cron.d/sanoid duplicate that only fires without systemd — not
    # ported). The NixOS module defaults to hourly, which would quietly
    # quarter the snapshot resolution, so it is set explicitly.
    interval = "*:0/15";

    templates.production = {
      frequently = 0;
      hourly = 0;
      daily = 5;
      monthly = 3;
      yearly = 0;
      autosnap = true;
      autoprune = true;
    };

    datasets = {
      ########################################################################
      ## Pre-existing Ubuntu entries, carried unchanged.
      ########################################################################
      "bank10/srv/gitea".use_template = production;
      "bank10/vital".use_template = production;
      "bank7/music".use_template = production;

      # The rpool root dataset itself. Non-recursive, so this covers `rpool`
      # only and nothing under it — every child below is listed on its own.
      "rpool".use_template = production;

      # Renamed in Window A from rpool/USERDATA/{root,myers}_ebnmd1.
      "rpool/home/root".use_template = production;
      "rpool/home/myers".use_template = production;

      "rpool/srv/postgresql".use_template = production;

      ########################################################################
      ## New in ticket 07's manifest — every row marked Sanoid "y".
      ########################################################################

      # NixOS' own tree. `rpool/nixos/root` and `rpool/nixos/log` are marked
      # "y"; `rpool/nixos/nix` is marked "n" — see the assertion below.
      # `rpool/nixos` itself is canmount=off, a container, and gets nothing.
      "rpool/nixos/root".use_template = production;
      "rpool/nixos/log".use_template = production;

      # `rpool/home` itself is a container (mountpoint=/home, no state of its
      # own) and is marked "n". The four new per-user homes are "y".
      "rpool/home/laura".use_template = production;
      "rpool/home/lillian".use_template = production;
      "rpool/home/arthur".use_template = production;
      "rpool/home/zeke".use_template = production;

      # Host secrets: hashedPasswordFiles, SSH host keys, postfix sasl_passwd,
      # NUT passwords, a redundant copy of the k3s token. Snapshotted, and
      # NEVER pushed off-box (ticket 07 item 11).
      "rpool/srv/secrets".use_template = production;

      # k3s control-plane state. Window B boots a clone of this (ticket 09).
      "rpool/srv/k3s".use_template = production;

      # The four /srv services that moved out of Ubuntu's root dataset.
      "rpool/srv/vaultwarden".use_template = production;
      "rpool/srv/winshiphouse".use_template = production;
      "rpool/srv/vikunja-mcp".use_template = production;
      "rpool/srv/actual-mcp-cottage".use_template = production;

      # Shared service state. `samba` carries passdb.tdb/secrets.tdb, which
      # ticket 05 finding 6 calls first-class migration state: losing it means
      # four Time Machine clients re-authenticating, possibly with full
      # backups. `libvirt` also gets a manual snapshot before each VM's first
      # NixOS boot — that is a runbook step, not something this file can do.
      "rpool/srv/samba".use_template = production;
      "rpool/srv/libvirt".use_template = production;
      "rpool/srv/smartmontools".use_template = production;

      # NUT state. `rpool/srv/nut-state` is canmount=off, a container, "n".
      "rpool/srv/nut-state/notify".use_template = production;
      "rpool/srv/nut-state/events-repair".use_template = production;
    };
  };

  ##########################################################################
  ## The two exclusions, made enforceable.
  ##
  ## Both are "n" in ticket 07's manifest and both would be actively harmful:
  ##
  ##   rpool/srv/crash — 48 GiB of kernel dumps today and growing by ~16 GiB
  ##     per incident. Snapshots would pin every dump forever and defeat the
  ##     point of pruning /var/crash after an investigation closes.
  ##   rpool/nixos/nix — the Nix store. Content-addressed, fully reproducible
  ##     from the flake, and rewritten on every `nixos-rebuild`; snapshots
  ##     would hold every garbage-collected path alive and make `nix-collect-
  ##     garbage` return nothing.
  ##
  ## Sanoid entries are non-recursive, so merely not listing them is already
  ## correct. The assertion exists so that a future edit which *adds* them —
  ## or which makes a parent recursive — fails at eval instead of silently
  ## filling rpool.
  ##########################################################################
  assertions =
    let
      forbidden = [
        "rpool/srv/crash"
        "rpool/nixos/nix"
      ];
      named = lib.attrNames config.services.sanoid.datasets;
      offenders = lib.intersectLists forbidden named;
    in
    [
      {
        assertion = offenders == [ ];
        message =
          "sanoid.nix: ticket 07 excludes these datasets from Sanoid, but they are configured: "
          + lib.concatStringsSep ", " offenders;
      }
      {
        assertion = !(lib.any (d: d.recursive != false) (lib.attrValues config.services.sanoid.datasets));
        message =
          "sanoid.nix: ticket 07 requires every Sanoid entry to be non-recursive and keyed by "
          + "dataset name. A recursive entry would silently pull in rpool/srv/crash and "
          + "rpool/nixos/nix.";
      }
    ];
}
