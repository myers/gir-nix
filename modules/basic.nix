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
    # the cluster is k3s, but helm is not part of services.k3s
    kubernetes-helm
    # nor is the Flux CLI, and ~/p/fluxing's `bin/inv flux.reconcile` shells out
    # to it. nixpkgs 2.9.4 matches the controllers in the cluster (v2.9.4); if
    # they drift more than a minor apart, `flux check` says so.
    fluxcd
  ];
}
