# Host configuration for gir. The boot half is ticket 12's skeleton; the service
# modules are ticket 24's port. Each module owns one area and nothing else:
# storage.nix owns every fileSystems entry outside this file, users.nix owns the
# accounts, and the three hand-written units have no upstream NixOS module.
{ pkgs, ... }:

{
  imports = [
    ../../modules/storage.nix
    ../../modules/users.nix
    ../../modules/hygiene.nix
    ../../modules/postgresql.nix
    ../../modules/plex.nix
    ../../modules/netconsole.nix
    ../../modules/kdump.nix
    ../../modules/ipmievd.nix
    ../../modules/samba.nix
    ../../modules/nut.nix
    ../../modules/ssh.nix
    ../../modules/libvirt.nix
    ../../modules/monitoring.nix
    ../../modules/sanoid.nix
    ../../modules/sysctl.nix
    ../../modules/networking.nix
    ../../modules/zfs-maintenance.nix
  ];

  networking.hostName = "gir";
  networking.hostId = "375d89cc";

  # Ticket 02: pin, do not compute.
  boot.kernelPackages = pkgs.linuxPackages_6_12;
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.package = pkgs.zfs_2_3;
  boot.zfs.devNodes = "/dev/disk/by-id";
  # hostId matches Ubuntu's, so a clean import never needs -f; the 26.11 default.
  boot.zfs.forceImportRoot = false;

  # Ticket 06: systemd-boot on ESP #2 only; never touch BootOrder.
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
    editor = false;
  };
  boot.loader.timeout = 5;
  boot.loader.efi.canTouchEfiVariables = false;

  # Ticket 07: NixOS's own tree, all legacy mountpoints.
  fileSystems."/" = {
    device = "rpool/nixos/root";
    fsType = "zfs";
  };
  fileSystems."/nix" = {
    device = "rpool/nixos/nix";
    fsType = "zfs";
    neededForBoot = true;
  };
  fileSystems."/var/log" = {
    device = "rpool/nixos/log";
    fsType = "zfs";
    neededForBoot = true;
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/9E8F-2366";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  # Ticket 13: pinned via the flake's k3s-pin overlay; k3s-guard.nix enforces it.
  services.k3s = {
    enable = true;
    package = pkgs.k3s_1_34_4;
  };

  system.stateVersion = "26.05";
}
