# Host configuration for gir. The boot half is ticket 12's skeleton; the service
# modules are ticket 24's port. Each module owns one area and nothing else:
# storage.nix owns every fileSystems entry outside this file, users.nix owns the
# accounts, and the three hand-written units have no upstream NixOS module.
{ lib, pkgs, ... }:

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

  # Window B (ticket 23) boots this entry FIRST: everything that can write to a shared
  # dataset or bring up 126 pods is off, so the first NixOS boot proves only the things
  # that must be true before anything else can be trusted — stage-1 mounts, the secrets
  # dataset, console login, network identity, netconsole and kdump.
  #
  # systemd-boot shows it as a separate entry ("NixOS - staged"). It exists because
  # boot.loader.systemd-boot.editor = false, so kernel params cannot be edited at the
  # menu. Reboot into the default entry to advance; nothing here persists.
  specialisation.staged.configuration = {
    # It differs ONLY in what starts at boot -- not in the configuration itself.
    # Disabling the services instead (services.k3s.enable = false, etc.) drops their
    # accounts and ids too, which breaks libvirt.nix's assertion that qemu keeps
    # Ubuntu's 64055:109, and would mean the staged boot proves a DIFFERENT system
    # from the one you are about to run. wantedBy = [] keeps every unit, account and
    # id identical and simply does not pull them into multi-user.target.
    systemd.services.k3s.wantedBy = lib.mkForce [ ];
    systemd.services.postgresql.wantedBy = lib.mkForce [ ];
    systemd.services.plex.wantedBy = lib.mkForce [ ];
    systemd.services.samba-smbd.wantedBy = lib.mkForce [ ];
    systemd.services.samba-nmbd.wantedBy = lib.mkForce [ ];
    systemd.services.libvirtd.wantedBy = lib.mkForce [ ];
    # libvirtd is socket-activated, so the sockets have to go too or the first
    # virsh call starts it anyway.
    systemd.sockets.libvirtd.wantedBy = lib.mkForce [ ];
    systemd.sockets.libvirtd-ro.wantedBy = lib.mkForce [ ];
    systemd.sockets.libvirtd-admin.wantedBy = lib.mkForce [ ];
    systemd.services.coding-hive-net.wantedBy = lib.mkForce [ ];
  };

  system.stateVersion = "26.05";
}
