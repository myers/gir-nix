# gir: Syncthing, native, replacing the root-podman container.
#
# Why this module exists. Syncthing ran on Ubuntu as a podman container
# (`~/p/syncthing/docker-compose.yml`, image `lscr.io/linuxserver/syncthing`,
# started by `sudo podman-compose up -d`). Podman did not survive the NixOS
# cutover, and the container was already broken before it: its restart policy was
# `unless-stopped`, while `podman-restart.service` only starts `always`
# containers, so it never came back after a reboot. Its own README records the
# reason it had to run as root -- "you get weird stuff with permissions when
# running as the `myers` user (due to rootless mode)". A native systemd service
# running as a real user has none of that problem.
#
# See `.scratch/no-ext4-on-zvol/issues/01-containers-storage-off-ext4.md` (which
# removed the podman GraphRoot mount) and ticket 05's keep/drop table.
{
  config,
  lib,
  ...
}:

let
  # The container bind-mounted `~/p/syncthing/config` at `/config`. This is that
  # same directory, named natively. It holds cert.pem/key.pem -- and therefore
  # the device ID FNYA4B2… that `minitrouble` already trusts -- plus config.xml
  # and the index-v2/ SQLite databases (~900 MiB). Pointing at it rather than
  # letting the module create a fresh one is what makes this a move and not a
  # new install: no re-pairing, no full rescan.
  configDir = "/home/myers/p/syncthing/config";

  # Every folder path in config.xml, plus the config directory itself. The
  # compose file bind-mounted /stuff and /srv/videotapes at identical paths
  # inside the container, so the four folder paths port 1:1 and are not restated
  # here -- only the mounts underneath them are:
  #   /stuff          -> bank9/stuff
  #   /srv/videotapes -> bank10/srv/videotapes
  #   /home/myers/p   -> vmpool/myers/p   (carries configDir)
  requiredMounts = [
    "/stuff"
    "/srv/videotapes"
    "/home/myers/p"
  ];
in
{
  services.syncthing = {
    enable = true;

    # PUID=1000/PGID=1000 in the compose file. Everything under configDir and
    # every folder path is already owned by myers:myers, so this is ownership
    # parity, not a migration.
    user = "myers";
    group = "myers";

    inherit configDir;

    # `databaseDir` defaults to configDir, which is what we want: index-v2/ is
    # already there. Stated explicitly so a future change to dataDir cannot move
    # the databases out from under Syncthing and trigger a rescan of every
    # folder.
    databaseDir = configDir;

    dataDir = "/home/myers/p/syncthing";

    ##########################################################################
    # Do NOT set `settings`. This is the sharp edge of the NixOS module.
    ##########################################################################
    #
    # `services.syncthing.settings` is declarative-config-as-source-of-truth:
    # when it is non-empty the module creates `syncthing-init.service`, which
    # PUTs the Nix-derived config over the running Syncthing's API. With
    # `overrideDevices`/`overrideFolders` at their defaults (both `true`), any
    # device or folder not named in Nix is *deleted*. Declaring an empty
    # `settings` and letting the defaults stand would therefore remove both
    # devices and all four folders on the first start.
    #
    # The escape hatch is the module's own guard:
    #     syncthing-init = mkIf (cleanedConfig != { }) { ... }
    # Leave `settings` unset and the unit is never generated, so nothing ever
    # rewrites config.xml. Syncthing simply reads the file that is already there.
    #
    # The two `override*` lines below are belt-and-braces for the day someone
    # does add a `settings` block: they keep web-UI-created devices and folders
    # from being deleted behind the user's back. They are not what makes the
    # config safe today -- the absent `settings` is.
    overrideDevices = false;
    overrideFolders = false;

    # Matches <gui><address> in config.xml. The module passes this as
    # `--gui-address`, which takes precedence over the file, so the two must not
    # drift. Localhost-only is deliberate and is a change in reachability from
    # the container: podman published 8384 to the host, so the GUI was reachable
    # across the LAN even though Syncthing bound 127.0.0.1 inside the container's
    # netns. Natively this binding means gir-only. Reach it with
    #     ssh -L 8384:127.0.0.1:8384 gir
    # The GUI has tls="false", so keeping it off the LAN also keeps the bcrypt
    # admin password off the wire.
    guiAddress = "127.0.0.1:8384";

    # Ticket 14: the host firewall is off entirely (`networking.firewall.enable
    # = false` in networking.nix), so there is nothing to open for 22000/tcp,
    # 22000/udp or 21027/udp. Explicit -- and `false` rather than omitted -- so
    # that a later decision to turn the firewall on has to revisit this line
    # instead of silently leaving Syncthing unreachable.
    openDefaultPorts = false;

    # `cert` and `key` are deliberately unset. Setting them makes the module
    # `install` its own files over configDir/cert.pem and configDir/key.pem,
    # which would issue a new device ID and break the pairing with minitrouble.
  };

  # Filesystem confinement (2026-09-20, in answer to "is there an advantage to
  # rootless podman?"). The honest part of that question was isolation: the
  # nixpkgs module sets a good deal of hardening (MemoryDenyWriteExecute,
  # PrivateUsers, PrivateDevices, RestrictNamespaces...) but leaves
  # `ProtectHome=no`, `ProtectSystem=no` and no path allowlist at all. So
  # Syncthing ran as `myers` with read/write over everything myers owns --
  # ~/.ssh, ~/p/gir-nix, tokens -- while being an internet-facing daemon: 22000
  # is open and the peer connects from a public address.
  #
  # A rootless container would have confined it to three bind mounts, but at the
  # cost of subuid-mapped file ownership on /stuff (shared with samba and plex),
  # a fuse-overlayfs graph root on ZFS, and -- worst -- losing the mount guard
  # below, because `podman -v /stuff:/stuff` *creates* a missing host path
  # instead of refusing to start. This gets the same confinement with none of
  # that, and is tighter than the old container actually was: that one ran under
  # root-podman (see the project README), so an escape landed as root.
  #
  # BindPaths rather than ReadWritePaths for the config tree: ProtectHome=tmpfs
  # masks /home first, so the path has to be mounted back in, and BindPaths is
  # read-write by default. /stuff and /srv/videotapes sit outside /home, so they
  # only need the ProtectSystem=strict exemption.
  #
  # NOT narrowed here: RestrictAddressFamilies. Syncthing needs AF_INET/INET6
  # for sync, AF_UNIX, and AF_NETLINK to enumerate interfaces for local
  # discovery; getting that list wrong breaks discovery quietly rather than
  # loudly. Separate decision, with its own testing.
  systemd.services.syncthing.serviceConfig = {
    ProtectHome = "tmpfs";
    BindPaths = [ "/home/myers/p/syncthing" ];
    ProtectSystem = "strict";
    ReadWritePaths = [
      "/stuff"
      "/srv/videotapes"
    ];
  };

  # Fail-closed on the three ZFS mounts (ticket 07, rule 9). This matters more
  # for Syncthing than for most services: all four folders are `sendreceive`, so
  # if Syncthing started against an unmounted /stuff it would scan an empty
  # directory, conclude every file had been deleted, and propagate those
  # deletions to the peer. Syncthing's own `.stfolder` marker check is the first
  # line of defence -- it refuses a folder whose marker is missing -- but the
  # mount guard is the one that keeps the service from starting at all.
  systemd.services.syncthing.unitConfig.RequiresMountsFor = requiredMounts;

  assertions = [
    {
      # Catches the failure mode the long comment above describes. If a future
      # edit adds devices or folders to `settings`, syncthing-init starts
      # generating -- and with it the override semantics. Fail the build and
      # make whoever does it read that comment first.
      assertion =
        config.services.syncthing.settings.devices == { }
        && config.services.syncthing.settings.folders == { };
      message = ''
        gir: modules/syncthing.nix intentionally leaves services.syncthing.settings
        unset so that config.xml (${configDir}/config.xml) stays the source of truth.
        Declaring devices or folders generates syncthing-init.service, which rewrites
        that file. If this is intended, delete this assertion deliberately and make
        sure overrideDevices/overrideFolders stay false.
      '';
    }
  ];
}
