# gir: basic tools — the interactive and diagnostic tools used at the console,
# over ssh and over BMC-KVM. Split out of hygiene.nix (ticket 24, module 13).
#
# Deliberately small: what is actually installed and used on the Ubuntu host
# (checked against `apt-mark showmanual`, 2026-09-19). Anything a service
# module pulls in is NOT repeated here — smartmontools, ipmitool, dmidecode,
# mdadm, sysstat, samba, postgresql clients, the ZFS userland and kubectl all
# arrive with their own module.
{ pkgs, ... }:

let
  # joe with backups off host-wide. Every personality's system rc (joerc,
  # jmacsrc, jpicorc, rjoerc, jstarrc, joerc.zh_TW) ships `-nobackups`
  # commented out by a leading space; moving it to column 1 turns it on. A
  # user's own ~/.joerc (or ~/.jmacsrc, ...) replaces the system file, so it
  # would need its own `-nobackups`.
  joe = pkgs.joe.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      for rc in $out/etc/joe/*rc $out/etc/joe/*rc.*; do
        sed -i 's/^ -nobackups\t/-nobackups\t/' "$rc"
      done
      grep -q '^-nobackups' $out/etc/joe/joerc
    '';
  });
in
{
  environment.systemPackages = with pkgs; [
    # editing and version control
    git
    vim
    joe
    # shells and multiplexers (zsh itself comes from programs.zsh in users.nix)
    screen
    # process and I/O inspection
    htop
    btop
    bottom
    lsof
    ncdu
    # text and data wrangling
    jq
    ripgrep
    file
    sqlite
    gnupg
    python3
    # transfer
    rsync
    curl
    wget
    # archives
    unzip
    # unzip only extracts; this is the Info-ZIP creator (added 2026-10-30)
    zip
    p7zip
    # hardware and network diagnosis — this host is debugged from the console
    # and over BMC-KVM during crash soaks
    pciutils
    usbutils
    nvme-cli
    lm_sensors
    ethtool
    # boot.loader.efi.canTouchEfiVariables = false, so NixOS never writes NVRAM and
    # nothing pulls efibootmgr in -- but that setting is exactly why this host edits
    # its boot entries by hand (ticket 06 put NixOS on ESP #2 without reordering
    # anything). Without this, `sudo efibootmgr` is "command not found" at the moment
    # you most need it, which is what happened promoting the BootOrder on 2026-09-20.
    efibootmgr
    # GNU parted (and partprobe). util-linux's fdisk/sfdisk cover most work, but the
    # Ventoy 1.1.17 linux tarball's Ventoy2Disk.sh refuses to partition a stick
    # without `parted`; it was missing when building a diagnostic USB on 2026-10-03.
    # The tarball's own blobs (vtoycli, static mkexfatfs) run as-is; nixpkgs' ventoy
    # is marked insecure and lags (1.1.12), so it is not installed here.
    parted
    # git LFS: zarn keeps fixtures in LFS on gt. Without the filter a clone of it only
    # half checks out (1,813 files left deleted in the index on 2026-10-05).
    git-lfs
    # the cluster is k3s, but helm is not part of services.k3s
    kubernetes-helm
    # nor is the Flux CLI, and ~/p/fluxing's `bin/inv flux.reconcile` shells out
    # to it. nixpkgs 2.9.4 matches the controllers in the cluster (v2.9.4); if
    # they drift more than a minor apart, `flux check` says so.
    fluxcd
    # the CI server is Woodpecker (ci.monoloco.net, v3.18.1 fork), and agents
    # read pipeline state with ~/.local/bin/wp, a wrapper that injects the server
    # and token and execs woodpecker-cli. Until 2026-10-01 the CLI was not on PATH
    # (the wrapper died with "exec: woodpecker-cli: not found" and was run through
    # `nix shell`). nixpkgs 3.18.0 is a patch behind the server; same minor.
    woodpecker-cli
  ];
}
