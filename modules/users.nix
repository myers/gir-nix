# gir: accounts and groups (ticket 24, module 2).
#
# Implements decisions already made; nothing here re-decides them:
#   * ticket 11 §7 — `users.mutableUsers = false`, one `hashedPasswordFile` per
#     account (root included) on the host-secrets dataset. Locked accounts stay
#     locked, because the hash copied out of Ubuntu's `/etc/shadow` is still
#     `!`/`*`. root gets a hash so the console and BMC-KVM login work when sudo
#     or the network does not.
#   * ticket 11 §"Downstream" — under `mutableUsers = false` every account and
#     every group membership must be declared, myers' `adm`, `sudo`→`wheel`,
#     `kvm`, `libvirt`, `lpadmin` and `sambashare` included.
#   * ticket 05 — Ollama is dropped, so uid 997 is free; plex is kept and must
#     keep uid/gid 998.
#   * ticket 07 — `rpool/srv/secrets` → `/etc/gir-secrets`, root 0700,
#     `neededForBoot`. It holds the password hashes *and* the SSH host keys.
#     The mount itself is declared in `storage.nix`, not here.
#
# Facts below (UID, GID, shell, home, GECOS, group membership) were read from
# the live Ubuntu `/etc/passwd` and `/etc/group` on 2026-09-19. No hash was read
# from `/etc/shadow`: the files under `/etc/gir-secrets` are written by the
# Window A sudo script, which scrubs its own output by literal value.
#
# Homes are NOT created and NOT chowned by this module. `createHome` stays at
# its default `false` for every account, because `/home/<user>` and `/root` are
# ZFS datasets carried over from Ubuntu with their ownership intact (ticket 11
# §1: "No `chown` runs anywhere").
{ lib, pkgs, ... }:

let
  # ticket 07: `rpool/srv/secrets`, mounted `neededForBoot` by storage.nix.
  secretsDir = "/etc/gir-secrets";

  # One file per account, as ticket 11 §7 specifies.
  hashFile = user: "${secretsDir}/hashed-password-${user}";

  # The SSH host keys live in a SUBDIRECTORY of the secrets dataset on purpose.
  # `sshd-keygen`'s script does `chmod 0755 "$(dirname <path>)"` for any key it
  # has to generate; pointing it at `${secretsDir}` directly would widen the
  # 0700 directory that holds the password hashes.
  sshKeyDir = "${secretsDir}/ssh";
in
{
  ############################################################################
  ## Authentication model (ticket 11 §7)
  ############################################################################

  users.mutableUsers = false;

  ############################################################################
  ## Groups
  ##
  ## Only the groups that must exist with a pinned GID are listed. NixOS's own
  ## defaults (wheel 1, adm 55, cdrom 24, lp 20, kvm 302, …) are left alone:
  ## their GIDs differ from Ubuntu's, but nothing on any *shared* dataset is
  ## group-owned by them, so the name is all that has to match.
  ############################################################################

  users.groups = {
    # Human accounts: these GIDs own files on the shared `rpool/home/*` datasets
    # and on `/srv/timemachine/*`, so they are parity-critical.
    myers.gid = 1000;
    laura.gid = 1001;
    lillian.gid = 1002;
    arthur.gid = 1003;
    zeke.gid = 1004;

    # ticket 05: plex is kept and `rpool/srv/plexmediaserver` is shared with
    # Ubuntu, where `Library/` is owned 998:998. nixpkgs' plex module pins
    # `ids.gids.plex` = 193, so this has to be forced.
    plex.gid = lib.mkForce 998;

    # NixOS has no `sambashare` group. Ubuntu's is GID 114 and myers is in it;
    # pinned so any group-owned file under the Samba tree keeps its name.
    # (ticket 05 drops the `[printers]`/`[print$]` shares and usershares, so
    # this group is membership parity only.)
    sambashare.gid = 114;

    # Declared, not pinned, so this module evaluates on its own before
    # `libvirt.nix` lands. `virtualisation.libvirtd` sets the GID (67) once it
    # is enabled; Ubuntu's `libvirt` group is GID 129, but nothing on
    # `rpool/srv/libvirt` is group-owned by it.
    libvirtd = { };
  };

  ############################################################################
  ## Accounts
  ############################################################################

  users.users = {
    # uid 0 / gid 0 / /root come from nixpkgs' own root definition; they are
    # repeated here only so this file states the parity it is responsible for.
    root = {
      uid = 0;
      group = "root";
      home = "/root";
      shell = pkgs.bashInteractive; # Ubuntu: /bin/bash
      hashedPasswordFile = hashFile "root";
    };

    myers = {
      isNormalUser = true;
      uid = 1000;
      group = "myers";
      home = "/home/myers";
      shell = pkgs.zsh; # Ubuntu: /bin/zsh (needs programs.zsh.enable, below)
      hashedPasswordFile = hashFile "myers";
      # Ubuntu's set was: adm(4) cdrom(24) sudo(27) dip(30) plugdev(46)
      # kvm(109) lpadmin(112) lxd(113) sambashare(114) libvirt(129)
      # docker(997) ollama(996). Translation, per ticket 11 §"Downstream":
      #   sudo     -> wheel       (NixOS's privileged group)
      #   libvirt  -> libvirtd    (nixpkgs names the admin group `libvirtd`)
      #   lpadmin  -> lp          (NixOS has no `lpadmin`; `lp` is the printing
      #                            group. CUPS itself is dropped by ticket 05,
      #                            so this is vestigial but harmless)
      #   adm, cdrom, kvm, sambashare carry over by name
      # Dropped on purpose, each because the service behind it is gone:
      #   dip     — pppd dialup, not installed on either OS
      #   plugdev — not a NixOS group; no udev rules use it on a headless host
      #   lxd     — snap-only on Ubuntu; snapd is dropped (ticket 05)
      #   docker  — docker is on ticket 07's leave-behind list; podman is
      #             rootless for myers and needs no group
      #   ollama  — ollama is dropped (ticket 05)
      extraGroups = [
        "wheel"
        "adm"
        "cdrom"
        "kvm"
        "libvirtd"
        "lp"
        "sambashare"
      ];
    };

    laura = {
      isNormalUser = true;
      uid = 1001;
      group = "laura";
      description = "Laura Carpenter";
      home = "/home/laura";
      shell = pkgs.bashInteractive;
      hashedPasswordFile = hashFile "laura";
    };

    lillian = {
      isNormalUser = true;
      uid = 1002;
      group = "lillian";
      description = "Lillian Carpenter";
      home = "/home/lillian";
      shell = pkgs.bashInteractive;
      hashedPasswordFile = hashFile "lillian";
    };

    arthur = {
      isNormalUser = true;
      uid = 1003;
      group = "arthur";
      description = "Arthur Carpenter";
      home = "/home/arthur";
      shell = pkgs.bashInteractive;
      hashedPasswordFile = hashFile "arthur";
    };

    zeke = {
      isNormalUser = true;
      uid = 1004;
      group = "zeke";
      description = "Zeke Trainum";
      home = "/home/zeke";
      shell = pkgs.bashInteractive;
      hashedPasswordFile = hashFile "zeke";
    };

    # ticket 05: plex is kept, overlay-pinned to 1.43.4.10903 by plex.nix, and
    # its data dataset (`rpool/srv/plexmediaserver` → /var/lib/plexmediaserver)
    # is shared with Ubuntu, where it is owned 998:998. nixpkgs' plex module
    # would create this account as uid 193, which would make Plex unable to read
    # its own database — hence the force.
    #
    # uid 997 (Ubuntu's `ollama`) is free because ticket 05 drops Ollama; this
    # module deliberately does not reuse it.
    plex = {
      uid = lib.mkForce 998;
      group = "plex";
      isSystemUser = true;
      home = "/var/lib/plexmediaserver";
    };
  };

  # The zsh shell above is only safe with the program enabled: nixpkgs asserts
  # `users.users.myers.shell == pkgs.zsh -> programs.zsh.enable`, and without it
  # the login shell has none of the Nix profile directories on PATH.
  programs.zsh.enable = true;

  ############################################################################
  ## SSH host keys (ticket 07 item 12)
  ##
  ## The keys are copies of Ubuntu's, carried on the secrets dataset, so that
  ## every client's known_hosts entry survives the cutover. Sizes are the live
  ## ones: RSA 3072 (not nixpkgs' 4096 default), ECDSA 256, ED25519.
  ##
  ## NOTE for ssh.nix (ticket 24 module 3): `hostKeys` is a list option, so a
  ## second definition CONCATENATES rather than replaces. ssh.nix must not set
  ## it as well.
  ############################################################################

  services.openssh.hostKeys = [
    {
      type = "ed25519";
      path = "${sshKeyDir}/ssh_host_ed25519_key";
    }
    {
      type = "rsa";
      bits = 3072;
      path = "${sshKeyDir}/ssh_host_rsa_key";
    }
    {
      type = "ecdsa";
      bits = 256;
      path = "${sshKeyDir}/ssh_host_ecdsa_key";
    }
  ];

  ############################################################################
  ## Cross-module UID/GID parity still owed by OTHER ticket-24 modules
  ##
  ## These are service accounts, not this module's accounts, but they own files
  ## on datasets that ticket 07 marks "shared", and nixpkgs will create them
  ## with different IDs. Each one is a silent data-access failure if ignored.
  ## Recorded here, deliberately NOT set, so the owning module decides between
  ## pinning the ID and chowning in Window A:
  ##
  ##   postgres      Ubuntu 110:119, nixpkgs ids 71:71.
  ##                 /var/lib/postgresql and /var/lib/postgresql/18 (on shared
  ##                 rpool/srv/postgresql) are owned 110:119 on disk.
  ##                 -> postgresql.nix (module 5)
  ##   libvirt-qemu  Ubuntu 64055, group kvm 109; nixpkgs runs qemu as
  ##                 `qemu-libvirtd` 301:301. /var/lib/libvirt/qemu (on shared
  ##                 rpool/srv/libvirt) is owned libvirt-qemu:kvm, mode 0750.
  ##                 -> libvirt.nix (module 8)
  ##   nut           Ubuntu 125:135. /var/lib/nut-events-repair (on shared
  ##                 rpool/srv/nut-state) is owned nut:nut.
  ##                 -> nut.nix (module 9)
  ##
  ## Not a problem, checked: the Nix build users already match. Ubuntu's
  ## existing Nix install uses gid 30000 and uids 30001-30032, which is exactly
  ## what NixOS derives from `ids.gids.nixbld` / `ids.uids.nixbld`. That matters
  ## because ticket 12 has both OSes mounting the same `rpool/nixos/nix` store.
  ############################################################################
}
