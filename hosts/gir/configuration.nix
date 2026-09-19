# Boot skeleton only (ticket 12): enough to prove evaluation, cache hits for
# the kernel, ZFS and k3s, and to measure the kernel+initrd pair on the ESP.
# Services are ported by later tickets.
{ pkgs, nixpkgs-k3s-1344, ... }:

{
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

  # Ticket 03's candidate; ticket 13 decides the mechanism.
  services.k3s = {
    enable = true;
    package = nixpkgs-k3s-1344.legacyPackages.${pkgs.stdenv.hostPlatform.system}.k3s_1_34;
  };

  system.stateVersion = "26.05";
}
