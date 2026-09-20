# Ticket 24 — netconsole sender (gir -> misfit).
#
# There is no NixOS module for netconsole, and the obvious route is a trap:
# nixpkgs builds CONFIG_NETCONSOLE=m, so `boot.kernelParams = [ "netconsole=..." ]`
# is parsed by nothing and silently does nothing. The working route on a modular
# build is the *dynamic* target: modprobe the module with no built-in target and
# create /sys/kernel/config/netconsole/<name> over configfs. Ubuntu's
# /usr/local/sbin/netconsole-misfit.sh already does exactly that, so this is that
# script ported as-is.
#
# Live values read off gir 2026-09-19 (/sys/kernel/config/netconsole/misfit):
#   dev_name=eno1  local_ip=192.168.42.8  local_port=6666
#   remote_ip=192.168.42.1  remote_mac=a0:36:9f:fb:67:94  remote_port=6666
#   extended=0  release=0  enabled=1  (local_mac 3c:ec:ef:7f:2a:96, set by the kernel)
#
# Only the *remote* side is baked in. The device and source address are
# re-derived from the default route at every start, exactly as Ubuntu does: the
# NIC name on this board has changed once already across a firmware update, and
# a witness that quietly stops working after a reboot is worse than no witness.
#
# Coverage is stage-2 only, as today: the target cannot exist before configfs and
# the interface do. Ticket 14: the squirrel *receiver* is dropped; this sender
# stays, and must be up from boot one.
{ config, lib, pkgs, ... }:

let
  name = "misfit";
  remoteIp = "192.168.42.1";
  remoteMac = "a0:36:9f:fb:67:94";
  port = "6666";
  cfgDir = "/sys/kernel/config/netconsole/${name}";
in
{
  # netconsole with no `netconsole=` parameter: loads with zero built-in
  # targets, which is what the configfs route wants. configfs is normally
  # built in; the request is harmless if it is.
  boot.kernelModules = [ "configfs" "netconsole" ];

  systemd.services."netconsole-${name}" = {
    description = "Stream kernel log to ${name} via netconsole";

    # Needs a routable source address, so it cannot precede the network. It is
    # ordered ahead of multi-user.target so the witness is armed before the
    # heavy stage-2 services (k3s, ZFS-backed services, libvirt) start — those
    # are what tend to wedge the box.
    after = [ "network-online.target" "sys-kernel-config.mount" ];
    wants = [ "network-online.target" "sys-kernel-config.mount" ];
    before = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [ kmod iproute2 util-linux coreutils gawk gnugrep ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "netconsole-${name}-start" ''
        set -u

        TGT_IP=${remoteIp}
        TGT_MAC=${remoteMac}
        PORT=${port}
        CFG=${cfgDir}

        SRC_DEV="''${SRC_DEV:-$(ip route show default | awk '/^default/{print $5; exit}')}"
        SRC_IP="''${SRC_IP:-$(ip route show default | grep -oE 'src [0-9.]+' | awk '{print $2; exit}')}"

        if [ -z "$SRC_DEV" ] || [ -z "$SRC_IP" ]; then
          echo "netconsole: no default route yet, refusing to arm a half-configured target" >&2
          exit 1
        fi

        modprobe configfs 2>/dev/null || true
        mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
        lsmod | grep -q '^netconsole' || modprobe netconsole || exit 1

        [ -d "$CFG" ] || mkdir "$CFG" || exit 1

        # Attributes are only writable while the target is disabled.
        echo 0 > "$CFG/enabled" 2>/dev/null || true
        echo "$SRC_DEV" > "$CFG/dev_name"
        echo "$SRC_IP"  > "$CFG/local_ip"
        echo "$TGT_IP"  > "$CFG/remote_ip"
        echo "$TGT_MAC" > "$CFG/remote_mac"
        echo "$PORT"    > "$CFG/local_port"
        echo "$PORT"    > "$CFG/remote_port"
        echo 1 > "$CFG/enabled"

        echo "netconsole: $SRC_IP/$SRC_DEV -> $TGT_IP:$PORT ($TGT_MAC)"
        echo "netconsole armed on ${config.networking.hostName} at $(date --iso-8601=seconds)" > /dev/kmsg
      ''}";

      ExecStop = "${pkgs.writeShellScript "netconsole-${name}-stop" ''
        set -u
        CFG=${cfgDir}
        [ -d "$CFG" ] || exit 0
        echo 0 > "$CFG/enabled" 2>/dev/null || true
        rmdir "$CFG" 2>/dev/null || true
        exit 0
      ''}";
    };
  };
}
