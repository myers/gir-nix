# Staggered ZFS scrubs and TRIM (ticket 05: "hand-written timers" + services.zfs.trim).
#
# Ported from Ubuntu's /etc/cron.d/zfs-scrub-staggered, installed there by
# apply-zfs-scrub-stagger.sh. One HDD pool per Sunday so two multi-day scrubs never
# overlap; durations below are measured from the July 2026 run.
#
# The stock Debian second-Sunday job is neutered on Ubuntu through the
# org.debian:periodic-scrub=disable pool property. That property is Debian-specific and
# nothing on NixOS reads it, so it is left alone — NixOS simply never installs a stock
# scrub job. services.zfs.autoScrub stays OFF for the same reason: it would scrub every
# pool on one timer, which is exactly what the stagger exists to prevent.
{ config, lib, pkgs, ... }:

let
  # Verbatim port of /usr/local/sbin/zfs-scrub-pool: skip a pool that is missing, not
  # ONLINE, or already scrubbing/resilvering, so a stagger slot can never pile onto a
  # degraded pool or a running resilver.
  zfs-scrub-pool = pkgs.writeShellApplication {
    name = "zfs-scrub-pool";
    runtimeInputs = [ config.boot.zfs.package ];
    text = ''
      for pool in "$@"; do
          health="$(zpool list -H -o health "$pool" 2>/dev/null || true)"

          if [ -z "$health" ]; then
              echo "zfs-scrub-pool: $pool: no such pool, skipping" >&2
              continue
          fi

          if [ "$health" != "ONLINE" ]; then
              echo "zfs-scrub-pool: $pool: health is $health, skipping" >&2
              continue
          fi

          if zpool status "$pool" | grep -qE '(scrub|resilver) in progress'; then
              echo "zfs-scrub-pool: $pool: already busy, skipping" >&2
              continue
          fi

          if [ "''${ZFS_SCRUB_DRYRUN:-0}" = "1" ]; then
              echo "zfs-scrub-pool: $pool: would scrub"
              continue
          fi

          zpool scrub "$pool" || echo "zfs-scrub-pool: $pool: scrub failed to start" >&2
      done
    '';
  };

  # week: which Sunday of the month. systemd calendar syntax expresses "the Nth Sunday"
  # as a day-of-month range plus Sun, which is the same trick the cron file used.
  slots = {
    # 1st Sunday: bank10, 111T raidz3, about 45 h
    bank10 = { when = "Sun *-*-01..07 00:24:00"; pools = [ "bank10" ]; };
    # 2nd Sunday: bank9, 59T raidz3, about 18 h
    bank9 = { when = "Sun *-*-08..14 00:24:00"; pools = [ "bank9" ]; };
    # 3rd Sunday: bank7, 28T raidz1, about 22 h
    bank7 = { when = "Sun *-*-15..21 00:24:00"; pools = [ "bank7" ]; };
    # 4th Sunday: the SSD/NVMe pools together — minutes each, negligible load
    ssd = { when = "Sun *-*-22..28 00:24:00"; pools = [ "rpool" "bpool" "vmpool" ]; };
  };

  mkScrubUnits = name: slot: {
    "zfs-scrub-${name}" = {
      description = "Staggered ZFS scrub: ${lib.concatStringsSep " " slot.pools}";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${zfs-scrub-pool}/bin/zfs-scrub-pool ${lib.concatStringsSep " " slot.pools}";
      };
    };
  };

  mkScrubTimers = name: slot: {
    "zfs-scrub-${name}" = {
      description = "Staggered ZFS scrub timer: ${lib.concatStringsSep " " slot.pools}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = slot.when;
        # Deliberately NOT Persistent: a scrub missed because the host was down should
        # wait for its next slot, not start at boot next to whatever else is running.
        Persistent = false;
        AccuracySec = "1h";
      };
    };
  };
in
{
  environment.systemPackages = [ zfs-scrub-pool ];

  systemd.services = lib.mkMerge (lib.mapAttrsToList mkScrubUnits slots);
  systemd.timers = lib.mkMerge (lib.mapAttrsToList mkScrubTimers slots);

  services.zfs.autoScrub.enable = false;

  # Ubuntu ran Debian's first-Sunday TRIM job. NixOS' own option is weekly, which is
  # fine for NVMe and is what upstream recommends; the pools it touches are the SSD ones
  # (HDD pools ignore TRIM).
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };

  # TODO(verify): after the first scrub slot fires on NixOS, confirm with
  #   systemctl list-timers 'zfs-*'
  # that the four timers show the same Sunday pattern, and that `zpool status` shows
  # only one pool scrubbing at a time. The cost of getting this wrong is two multi-day
  # scrubs overlapping on a host that already has a memory-pressure crash history.
}
