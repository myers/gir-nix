# gir: docker, for throwaway test clusters only (k3d / k3s-in-docker), added 2026-10-12.
#
# Why it exists: the zfs-localpv BDD suite (openebs/zfs-localpv PR #782, the #776 case)
# needs a disposable Kubernetes cluster, and gir's own k3s is production. Nothing
# else on gir uses docker; k3s keeps its own containerd and BuildKit shares it
# (docs/adr/0001-buildkit-shares-k3s-containerd.md in ~/p/gir). This module must not
# change that.
#
# Decisions, each one a way this could hurt the production k3s:
#   * Not running at rest. `enableOnBoot = false` leaves only docker.socket listening;
#     dockerd starts on the first `docker` call. `sudo systemctl stop docker.service
#     docker.socket` takes it away again.
#   * overlay2 on a plain dataset, never the ZFS graph driver (the user ran that and
#     called it a nightmare, 2026-09-20). Same shape as rpool/srv/containerd-fs:
#     xattr=sa, acltype=posixacl. data-root is /srv/docker, fail-closed with
#     RequiresMountsFor so a missing mount cannot fill `/`.
#   * `ip-forward-no-drop`: dockerd otherwise sets the iptables FORWARD policy to
#     DROP, which would sit under kube-router's rules and cut pod traffic if
#     anything in k3s's chain ever stopped matching. The firewall is off on gir
#     (networking.nix) and the backend is the iptables-nft shim, so docker and
#     kube-router share one ruleset. Docker's own chains (DOCKER, DOCKER-USER,
#     DOCKER-FORWARD) still get added; the 172.17.0.0/16 default bridge does not
#     overlap k3s's 10.42/16 and 10.43/16 or the 192.168.42/69 LANs.
#   * No user is added to the `docker` group: that group is root. Use `sudo docker`.
#
# Unverified until the first start: dockerd rejects unknown keys in daemon.json, so
# if `ip-forward-no-drop` is not accepted by docker 29.7.2 the service fails to start
# with the offending key in `journalctl -u docker`. A build only proves evaluation.
#
# Before `switch`, create the dataset (storage.nix mounts it):
#   zfs create -o mountpoint=/srv/docker -o xattr=sa -o acltype=posixacl \
#       -o compression=lz4 rpool/srv/docker
{ ... }:

{
  virtualisation.docker = {
    enable = true;
    enableOnBoot = false;
    storageDriver = "overlay2";
    daemon.settings = {
      data-root = "/srv/docker";
      ip-forward-no-drop = true;
    };
  };

  systemd.services.docker.unitConfig.RequiresMountsFor = [ "/srv/docker" ];
}
