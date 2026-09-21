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
    ../../modules/syncthing.nix
    ../../modules/sysstat.nix
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

  # Ticket 01 §1.2: Ubuntu ran `k3s server` with ZERO CLI flags -- /etc/rancher/k3s/
  # config.yaml (271 B) was the entire configuration surface, and it did not come
  # across. k3s reads this path by default, so writing the files is the whole port;
  # no extraFlags are needed.
  #
  # What its absence cost on the first NixOS boot (2026-09-20), all of it live:
  #   * node-ip     -- eno1 carries BOTH 192.168.42.8 and 192.168.69.1, and k3s chose
  #                    192.168.69.1 for the node InternalIP. Ubuntu pinned .42.8.
  #   * max-pods    -- fell back to the kubelet default of 110 with 119 pods already
  #                    scheduled on the node, so the node was over its own capacity.
  #   * disable     -- k3s redeployed its bundled traefik into kube-system, which
  #                    crash-looped on missing CRDs. The real traefik is Flux-managed
  #                    in the `traefik` namespace and was running the whole time.
  #   * audit-*     -- kube-apiserver audit logging silently stopped.
  environment.etc."rancher/k3s/config.yaml" = {
    mode = "0600";
    text = ''
      node-ip: 192.168.42.8
      disable:
        - traefik
      kubelet-arg:
        - "max-pods=250"
      kube-apiserver-arg:
        - audit-policy-file=/etc/rancher/k3s/audit-policy.yaml
        - audit-log-path=/var/log/k3s-audit.log
        - audit-log-maxage=30
        - audit-log-maxbackup=10
        - audit-log-maxsize=100
    '';
  };

  # Referenced by the audit-policy-file arg above. The apiserver will not start if it
  # is missing, so it is inlined here rather than carried as a file to copy.
  # Verbatim from Ubuntu (219 B, sha256:2e3137df...c08a96).
  environment.etc."rancher/k3s/audit-policy.yaml" = {
    mode = "0600";
    text = ''
      apiVersion: audit.k8s.io/v1
      kind: Policy
      omitStages:
        - RequestReceived
      rules:
        - level: Metadata
          verbs: ["create", "update", "delete"]
          resources:
            - group: ""
              resources: ["pods"]
        - level: None
    '';
  };

  # k3s reads /proc/net/route once at startup and exits fatally if there is no default
  # route. On the first NixOS boot (2026-09-20 12:42) libvirt attached macvtap0 to eno1
  # while k3s was starting; the attach bounces the 10G link's carrier, systemd-networkd
  # logged "eno1: DHCP lease lost", and the route was gone for seven seconds. k3s's three
  # default restarts are immediate, so all three landed inside that window and the unit
  # died of start-limit-hit with the network perfectly healthy a moment later.
  #
  # Ordering k3s after libvirt-guests.service would close this exact race but makes a
  # hang in guest resume block the cluster. Backing the restarts off instead costs a
  # slower recovery and fixes the whole class: any transient loss of the default route,
  # from any cause, is now ridden out rather than fatal. Ten tries at 15s covers ~150s.
  systemd.services.k3s = {
    serviceConfig.RestartSec = lib.mkForce "15s";
    startLimitIntervalSec = 300;
    startLimitBurst = 10;
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
