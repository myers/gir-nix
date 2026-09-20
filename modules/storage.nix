# gir: storage layout (ticket 24).
#
# Implements the dataset manifest in
# `.scratch/nixos-migration/issues/07-shared-state-dataset-manifest.md` and the
# layout Window A produces (`.scratch/nixos-migration/22-window-a-runbook.md`).
# Nothing here re-decides anything those tickets settled.
#
# Scope, and what deliberately is NOT here:
#   * `/`, `/nix`, `/var/log` and `/boot` are declared by hosts/gir/configuration.nix
#     (tickets 12 and 06). They are NixOS's own tree, all `mountpoint=legacy`.
#   * The ~113 hostPath app datasets on bank7/bank9/bank10/rpool are *not* listed in
#     `fileSystems`. They are mounted by `gir-zfs-mount-all.service` below, which is
#     this host's replacement for `zfs mount -a`.
#
# The rules this file encodes:
#   * Native `mountpoint` + `options = [ "zfsutil" ]` for everything a service needs,
#     except `rpool/srv/containerd-fs`, which stays `mountpoint=legacy`.
#   * Fail-closed: `RequiresMountsFor=` on each consuming unit, so a missing mount
#     stops the service instead of letting it write into `/`.
#   * NixOS NEVER runs `zfs mount -a` — it would mount Ubuntu's `/` and `/var/lib`
#     over NixOS's own.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # `mountpoint=legacy` datasets must not get `zfsutil`; everything else must.
  zfsOpts = [ "zfsutil" ];

  # Ubuntu's fstab ordering for the two ext4-on-zvol mounts, minus `nofail`
  # (ticket 07: dropbox loses `nofail` because it is the same ext4-on-zvol shape as
  # the jbd2 hang — a missing dropbox must stop k3s, not let pods write into `/`).
  #
  # `zfs-volumes.target` ships with the zfs package. NixOS does not pull it into the
  # boot by itself (nixos/modules/tasks/filesystems/zfs.nix wants only zfs-mount,
  # zfs-share and zfs-zed from zfs.target), but `x-systemd.requires=` creates both a
  # Requires= and an After= on it, which starts it and its `zfs-volume-wait.service`
  # on demand. That is what makes "ordered after the zvols appear" true.
  zvolOpts = [
    "x-systemd.requires=zfs-volumes.target"
    "x-systemd.device-timeout=10m"
  ];

  # Fail-closed wiring helper.
  mountsFor = paths: { unitConfig.RequiresMountsFor = paths; };
in
{
  ##############################################################################
  # 1. Pools
  ##############################################################################

  # rpool arrives via the root filesystem, vmpool via /home/myers/p. bank7, bank9
  # and bank10 are reached only through datasets this module does not name in
  # `fileSystems` — bank7 only through a *zvol device path*, which the zfs module
  # cannot see — so without this they would never be imported at all.
  boot.zfs.extraPools = [
    "bank7"
    "bank9"
    "bank10"
    "vmpool"
  ];

  ##############################################################################
  # 2. fileSystems — every dataset a service depends on
  ##############################################################################

  fileSystems = {
    # ---- host secrets -------------------------------------------------------
    # Holds the hashedPasswordFiles, so it must be present before activation.
    "/etc/gir-secrets" = {
      device = "rpool/srv/secrets";
      fsType = "zfs";
      options = zfsOpts;
      neededForBoot = true;
    };

    # ---- k3s ----------------------------------------------------------------
    # Ticket 09: NixOS boots a CLONE of the k3s datastore, never Ubuntu's original, so
    # rollback is "boot Ubuntu" with no restore step and nothing to undo. Window B's
    # quiesce script snapshots rpool/srv/k3s@pre-windowB and clones it to this name
    # BEFORE the BootNext — if the clone is missing this mount fails and k3s fails
    # closed with it, which is the intended behaviour, not a bug.
    # After a clean soak: `zfs promote rpool/srv/k3s-nixos`, then retire the original.
    "/var/lib/rancher/k3s" = {
      device = "rpool/srv/k3s-nixos";
      fsType = "zfs";
      options = zfsOpts;
    };

    # The one dataset that stays `mountpoint=legacy` (ticket 07). It keeps
    # `xattr=sa` + `acltype=posixacl` as dataset properties — k3s validates the
    # overlayfs-on-ZFS snapshotter at startup.
    "/var/lib/rancher/k3s/agent/containerd" = {
      device = "rpool/srv/containerd-fs";
      fsType = "zfs";
      # No "zfsutil": the dataset is legacy, so mount.zfs takes the fstab path.
      depends = [ "/var/lib/rancher/k3s" ];
    };

    # ---- the four /srv apps k3s fails closed on -----------------------------
    # On NixOS `/srv` itself is a plain directory on the root dataset; Ubuntu keeps
    # its own `rpool/ROOT/.../srv`.
    # apt-cacher-ng's package cache (gitea/apt-cache), moved off ROOT's /data in
    # Window A. Deliberately NOT in k3s's RequiresMountsFor below: it is regenerable,
    # and a missing cache must not stop the cluster. It relies on the mount-all unit
    # running before k3s, like the other ~113 hostPath datasets.
    "/srv/apt-cache" = {
      device = "rpool/srv/apt-cache";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/srv/vaultwarden" = {
      device = "rpool/srv/vaultwarden";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/srv/winshiphouse" = {
      device = "rpool/srv/winshiphouse";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/srv/vikunja-mcp" = {
      device = "rpool/srv/vikunja-mcp";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/srv/actual-mcp-cottage" = {
      device = "rpool/srv/actual-mcp-cottage";
      fsType = "zfs";
      options = zfsOpts;
    };

    # ---- native services ----------------------------------------------------
    "/var/lib/postgresql" = {
      device = "rpool/srv/postgresql";
      fsType = "zfs";
      options = zfsOpts;
    };

    # Ticket 07 says "as today", and today is /var/lib/plexmediaserver. nixpkgs'
    # services.plex defaults dataDir to /var/lib/plex, so the plex port must set
    # `services.plex.dataDir = "/var/lib/plexmediaserver"` or this mount is unused.
    "/var/lib/plexmediaserver" = {
      device = "rpool/srv/plexmediaserver";
      fsType = "zfs";
      options = zfsOpts;
    };

    "/var/lib/samba" = {
      device = "rpool/srv/samba";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/var/lib/libvirt" = {
      device = "rpool/srv/libvirt";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/var/lib/smartmontools" = {
      device = "rpool/srv/smartmontools";
      fsType = "zfs";
      options = zfsOpts;
    };

    # NUT: /var/lib/nut is deliberately NOT shared (runtime-only on NixOS).
    "/var/lib/nut-notify" = {
      device = "rpool/srv/nut-state/notify";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/var/lib/nut-events-repair" = {
      device = "rpool/srv/nut-state/events-repair";
      fsType = "zfs";
      options = zfsOpts;
    };

    # Shared with Ubuntu; starts empty (the three existing vmcores stay behind in
    # /var/crash.pre-windowA on Ubuntu).
    "/var/crash" = {
      device = "rpool/srv/crash";
      fsType = "zfs";
      options = zfsOpts;
    };

    # ---- homes (ticket 11, renamed out of rpool/USERDATA in Window A) --------
    "/home" = {
      device = "rpool/home";
      fsType = "zfs";
      options = zfsOpts;
    };
    "/home/myers" = {
      device = "rpool/home/myers";
      fsType = "zfs";
      options = zfsOpts;
      depends = [ "/home" ];
    };
    "/home/laura" = {
      device = "rpool/home/laura";
      fsType = "zfs";
      options = zfsOpts;
      depends = [ "/home" ];
    };
    "/home/lillian" = {
      device = "rpool/home/lillian";
      fsType = "zfs";
      options = zfsOpts;
      depends = [ "/home" ];
    };
    "/home/arthur" = {
      device = "rpool/home/arthur";
      fsType = "zfs";
      options = zfsOpts;
      depends = [ "/home" ];
    };
    "/home/zeke" = {
      device = "rpool/home/zeke";
      fsType = "zfs";
      options = zfsOpts;
      depends = [ "/home" ];
    };

    # Keeps its local mountpoint /root — Window A does not `zfs inherit`, so this
    # is NOT nested under /home and gets no `depends`.
    "/root" = {
      device = "rpool/home/root";
      fsType = "zfs";
      options = zfsOpts;
    };

    # vmpool/myers/p stacks on /home/myers and must mount after it. systemd orders
    # nested mount units on its own; `depends` states it anyway, and it is the only
    # thing that still holds if the two ever stop being path-nested. This carries
    # syncthing's 828 MiB /config, so it is not optional.
    "/home/myers/p" = {
      device = "vmpool/myers/p";
      fsType = "zfs";
      options = zfsOpts;
      depends = [ "/home/myers" ];
    };

    # ---- ext4 on zvol -------------------------------------------------------
    # Nine pod hostPaths live inside this one. NO `nofail` (ticket 07).
    "/srv/dropbox" = {
      device = "/dev/zvol/bank7/dropbox";
      fsType = "ext4";
      options = zvolOpts;
    };

    # Root podman's GraphRoot: image layers *and* libpod's container database.
    # Ubuntu's fstab has no zvol ordering on this one; ticket 24 adds it, because it
    # is the same ext4-on-zvol shape as dropbox.
    "/var/lib/containers/storage" = {
      device = "/dev/zvol/rpool/srv/podman";
      fsType = "ext4";
      options = zvolOpts ++ [ "errors=remount-ro" ];
    };

    # ---- the containerd binds Ubuntu's fstab carries ------------------------
    # "needed for buildkit?" in Ubuntu's fstab. The source is the containerd-fs
    # mount, which exists at boot, so this one is an ordinary ordered bind.
    "/var/lib/containerd" = {
      device = "/var/lib/rancher/k3s/agent/containerd";
      fsType = "none";
      options = [ "bind" ];
      depends = [ "/var/lib/rancher/k3s/agent/containerd" ];
    };

    # /run/k3s/containerd does not exist until k3s has started, so this bind cannot
    # be copied out of fstab literally: at boot the source is missing and the mount
    # fails. It is therefore `noauto`, pulled in *by* k3s and ordered after it
    # (`x-systemd.requires=` yields both Requires= and After=).
    #
    # TODO(collect): verify on the first NixOS boot that /run/k3s/containerd already
    # exists at the moment k3s.service reaches "started" — k3s is Type=notify and
    # notifies after its containerd is up, so it should. If it races, replace this
    # with a small oneshot that polls for the directory before binding.
    "/run/containerd" = {
      device = "/run/k3s/containerd";
      fsType = "none";
      options = [
        "bind"
        "noauto"
        "x-systemd.requires=k3s.service"
        "x-systemd.wanted-by=k3s.service"
      ];
    };
  };

  ##############################################################################
  # 3. Swap: mdadm RAID1 (md0) across the two PNY CS3040 NVMe drives
  ##############################################################################
  #
  # /proc/mdstat: `md0 : active raid1 nvme0n1p2[0] nvme1n1p2[1]`, 11525120 blocks.
  # Ubuntu's fstab swaps on the signature UUID, which is what survives the array
  # being assembled under a different md minor.
  boot.swraid = {
    enable = true;
    # HOMEHOST is <ignore> on purpose: the array name is still "brainframe:0" from
    # a previous host, so under HOMEHOST <system> (== gir) mdadm treats it as
    # foreign and assembles it as /dev/md127. The explicit ARRAY line plus <ignore>
    # pins it back to /dev/md0. Ubuntu's /etc/mdadm/mdadm.conf has no ARRAY line at
    # all and gets md0 from udev incremental assembly.
    mdadmConf = ''
      HOMEHOST <ignore>
      MAILADDR root
      ARRAY /dev/md0 metadata=1.2 name=brainframe:0 UUID=70920069:56ba6d27:b27cf8c9:9d66d007
         devices=/dev/disk/by-id/nvme-PNY_CS3040_4TB_SSD_PNY212721070601001E6-part2,/dev/disk/by-id/nvme-PNY_CS3040_4TB_SSD_PNY212721070601001E9-part2
    '';
  };

  swapDevices = [
    {
      # /dev/md0, by the swap signature's UUID — the same one Ubuntu's fstab uses.
      device = "/dev/disk/by-uuid/0a70f011-bc24-421f-adba-48cf2e5fe8b6";
      # Ubuntu's bare `discard` == `swapon --discard` == both pages and clusters.
      discardPolicy = "both";
    }
  ];

  ##############################################################################
  # 4. systemd: fail-closed wiring + the mount-all replacement
  ##############################################################################

  systemd.services = lib.mkMerge [

    ############################################################################
    # 4a. RequiresMountsFor, per ticket 07's table.
    #
    # Each block is guarded on its service being enabled, so importing this module
    # before the matching service is ported does not synthesise a unit with no
    # ExecStart. The guards fall away on their own as the service tickets land.
    ############################################################################

    (lib.mkIf config.services.k3s.enable {
      k3s = {
        unitConfig.RequiresMountsFor = [
          "/var/lib/rancher/k3s"
          "/var/lib/rancher/k3s/agent/containerd"
          "/srv/dropbox"
          "/srv/vaultwarden"
          "/srv/winshiphouse"
          "/srv/vikunja-mcp"
          "/srv/actual-mcp-cottage"
        ];
        # Ticket 07: the other ~113 hostPath datasets are covered by Window A's
        # hard gate plus k3s being *ordered* after the mount-all unit. Ordering
        # only, not Requires= — one broken app dataset must not stop the cluster.
        after = [ "gir-zfs-mount-all.service" ];
      };
    })

    (lib.mkIf config.services.postgresql.enable {
      postgresql = mountsFor [ "/var/lib/postgresql" ];
    })

    (lib.mkIf config.services.plex.enable {
      # The unit is named "plex" on NixOS, not "plexmediaserver".
      plex = mountsFor [ "/var/lib/plexmediaserver" ];
    })

    (lib.mkIf config.services.samba.enable {
      samba-smbd = mountsFor [ "/var/lib/samba" ];
    })
    (lib.mkIf (config.services.samba.enable && config.services.samba.nmbd.enable) {
      samba-nmbd = mountsFor [ "/var/lib/samba" ];
    })
    (lib.mkIf (config.services.samba.enable && config.services.samba.winbindd.enable) {
      samba-winbindd = mountsFor [ "/var/lib/samba" ];
    })

    (lib.mkIf config.virtualisation.libvirtd.enable {
      libvirtd = mountsFor [ "/var/lib/libvirt" ];
    })

    (lib.mkIf config.services.smartd.enable {
      smartd = mountsFor [ "/var/lib/smartmontools" ];
    })

    (lib.mkIf config.virtualisation.podman.enable {
      # Both units ship with the podman package via systemd.packages, so NixOS
      # writes these as drop-ins (overrideStrategy defaults to asDropinIfExists).
      podman = mountsFor [ "/var/lib/containers/storage" ];
      podman-restart = mountsFor [ "/var/lib/containers/storage" ];
    })

    # Closed by modules/nut.nix, which names these two units. They set the same
    # RequiresMountsFor themselves; unitConfig list values concatenate, so both
    # definitions coexist.
    (lib.mkIf config.power.ups.enable {
      nut-notify = mountsFor [ "/var/lib/nut-notify" ];
      nut-events-repair = mountsFor [ "/var/lib/nut-events-repair" ];
    })
    #
    # Closed by modules/kdump.nix: the unit is `kdump-capture.service` and it sets
    # its own RequiresMountsFor = /var/crash, so nothing is needed here.
    # Historical note: on Ubuntu it is
    # `kdump-tools-dump.service` with KDUMP_COREDIR=/var/crash and *no* mount
    # dependency (ticket 22 records this). nixpkgs has no kdump-tools module, so the
    # NixOS-side unit name is not knowable until the kdump port picks one; it must
    # then get `RequiresMountsFor = [ "/var/crash" ]`. Ticket 22 already books the
    # unproven capture path as an accepted residual risk.

    ############################################################################
    # 4b. NixOS must never run `zfs mount -a`.
    ############################################################################

    {
      # Upstream zfs-mount.service is literally `zfs mount -a`. On this host that
      # would mount Ubuntu's rpool/ROOT/ubuntu_ebnmd1 over NixOS's `/` and
      # .../var/lib over NixOS's /var/lib. Mask it outright. (nixpkgs' zfs module
      # puts it in zfs.target.wants; enable = false replaces the unit with a
      # symlink to /dev/null and drops that .wants link.)
      zfs-mount.enable = lib.mkForce false;

      # There is deliberately no /etc/zfs/zfs-list.cache on NixOS either: it would
      # re-enable the same behaviour through zfs-mount-generator, which is how
      # Ubuntu mounts rpool and bpool today.
      gir-zfs-mount-all = {
        description = "Mount gir's shared ZFS datasets (replaces zfs mount -a)";

        # Ordered after the `fileSystems` mounts (local-fs.target) and after the
        # pools are imported, so everything declared above is already in place and
        # is simply skipped below.
        requires = [ "zfs-import.target" ];
        after = [
          "zfs-import.target"
          "zfs.target"
          "local-fs.target"
        ];
        before = [ "k3s.service" ];
        wantedBy = [ "multi-user.target" ];

        path = [
          config.boot.zfs.package
          pkgs.gawk
          pkgs.util-linux
          pkgs.coreutils
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          set -euo pipefail

          TAB=$(printf '\t')

          work=$(mktemp)
          trap 'rm -f "$work"' EXIT

          # Candidate set: every canmount=on dataset with a native mountpoint,
          # minus Ubuntu's boot environment, minus the zsys USERDATA hierarchy and
          # minus bpool. `mountpoint=legacy` and `mountpoint=none` fall out via the
          # /^\// test, which is also what keeps NixOS's own rpool/nixos/* out.
          zfs list -H -t filesystem -o name,mountpoint,canmount,mounted |
            awk -F"$TAB" '
              $3 != "on"                 { next }
              $2 !~ /^\//                { next }
              $1 == "rpool/ROOT"         { next }
              $1 ~  /^rpool\/ROOT\//     { next }
              $1 == "rpool/USERDATA"     { next }
              $1 ~  /^rpool\/USERDATA\// { next }
              $1 == "bpool"              { next }
              $1 ~  /^bpool\//           { next }
                                         { print $1 "\t" $2 "\t" $4 }
            ' | LC_ALL=C sort -t"$TAB" -k2,2 > "$work"

          if [ ! -s "$work" ]; then
            echo "gir-zfs-mount-all: no candidate datasets; nothing to do." >&2
            exit 0
          fi

          # ------------------------------------------------------------ gate 1
          # Hard duplicate-mountpoint gate. Two datasets on one mountpoint is the
          # /srv/ombi and /srv/pyload defect (ticket 04): the loser is invisible
          # and which one wins is decided by pool import order. Abort; mount
          # nothing.
          dups=$(cut -f2 "$work" | LC_ALL=C sort | uniq -d || true)
          if [ -n "$dups" ]; then
            echo "ABORT: duplicate ZFS mountpoints in the mount set. Nothing was mounted." >&2
            printf '%s\n' "$dups" | while IFS= read -r mp; do
              [ -n "$mp" ] || continue
              awk -F"$TAB" -v m="$mp" '$2 == m { print "  " $2 "  <- " $1 }' "$work" >&2
            done
            echo "Fix it with: zfs set mountpoint=none <fossil>   (ticket 04), then retry." >&2
            exit 1
          fi

          # ------------------------------------------------------------ gate 2
          # An unmounted candidate whose mountpoint is already somebody else's
          # mount is the same defect wearing a different hat. Still before any
          # mounting.
          conflict=0
          while IFS="$TAB" read -r name mp mounted; do
            [ -n "$name" ] || continue
            [ "$mounted" = "no" ] || continue
            if findmnt --mountpoint "$mp" >/dev/null 2>&1; then
              src=$(findmnt -n -o SOURCE --mountpoint "$mp" || true)
              echo "ABORT: $mp is already a mount point (source: $src) but $name is not mounted there." >&2
              conflict=1
            fi
          done < "$work"

          if [ "$conflict" -ne 0 ]; then
            echo "Nothing was mounted." >&2
            exit 1
          fi

          # ------------------------------------------------------------- mount
          # Sorted by mountpoint, so a parent always precedes its children
          # (/home before /home/myers before /home/myers/p; /stuff before
          # /stuff/srv). Datasets already mounted by `fileSystems` are skipped.
          rc=0
          while IFS="$TAB" read -r name mp mounted; do
            [ -n "$name" ] || continue
            if [ "$mounted" = "yes" ]; then
              continue
            fi
            echo "mounting $name at $mp"
            if ! zfs mount "$name"; then
              echo "FAILED to mount $name at $mp" >&2
              rc=1
            fi
          done < "$work"

          exit "$rc"
        '';
      };
    }
  ];
}
