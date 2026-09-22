{ options, pkgs, ... }:
{
  ############################################################################
  ## plocate -- `locate` with a nightly updatedb
  ##
  ## Ubuntu had plocate (daily plocate-updatedb.timer); the fossil-copies
  ## ticket leaned on it to answer "does this file exist elsewhere?". hygiene.nix
  ## lists the packages that came over and this was not among them, so NixOS ran
  ## from the 2026-09-20 cutover without it.
  ##
  ## The NixOS module installs the package, creates the `plocate` group with a
  ## setgid `locate`/`plocate` wrapper, and runs updatedb from a timer at
  ## Nice=19 / IOSchedulingClass=idle. The prune list is what matters on this
  ## host: a full updatedb walk is exactly the kind of whole-tree metadata scan
  ## that has driven ARC pressure here (see the 2026-09-20 arc_prune / containerd
  ## outcome), so container storage is kept out of it entirely. The stock
  ## pruneFS list predates overlayfs; without `overlay` every running container's
  ## rootfs (~70 mounts) would be indexed.
  ############################################################################
  services.locate = let dflt = options.services.locate; in {
    enable = true;
    package = pkgs.plocate;
    # default 02:15 daily; clear of the 00:24 scrub slots and the 04:30 nut job.
    # Setting a list option replaces its default; append to it instead.
    pruneFS = dflt.pruneFS.default ++ [ "overlay" "nsfs" ];
    prunePaths = dflt.prunePaths.default ++ [
      # containerd content and snapshots (k3s shares the containerd store with
      # BuildKit; walking Active snapshots is the arc_prune trigger).
      "/var/lib/rancher/k3s/agent/containerd"
      "/var/lib/containerd"
      # pod volumes and projected secrets; bind/tmpfs mounts that churn per pod.
      "/var/lib/kubelet"
      # vmcores: a handful of multi-GB files, nothing to find by name.
      "/var/crash"
      # Ubuntu pruned this too. gcd_covers alone is 223k subdirectories under
      # one parent: a machine-generated cover cache nobody looks up by name,
      # and the first NixOS run died there after 72 minutes (2026-09-22).
      "/comics/managed"
    ];
  };

  # updatedb opens a descriptor per pending subdirectory, so a directory with
  # more children than the fd limit aborts the whole run ("Too many open
  # files", limit 131072). Raise it to the kernel ceiling (fs.nr_open).
  systemd.services.update-locatedb.serviceConfig.LimitNOFILE = 1048576;
}
