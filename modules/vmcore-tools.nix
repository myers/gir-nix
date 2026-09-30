# Reading a vmcore on this host: drgn, plus the debug info it needs.
#
# Neither crash nor drgn is in nixpkgs, so both are local (pkgs/). drgn reads the
# makedumpfile output kdump.nix writes (/var/crash/<stamp>/dump.<stamp>) through
# libkdumpfile, and it needs DWARF for the kernel and for zfs/spl:
#
#   kernel  /etc/gir-debuginfo/kernel/vmlinux         (linux-<ver>-dev, full DWARF)
#   zfs/spl /etc/gir-debuginfo/zfs/{zfs,spl}.ko.debug (modules/zfs-debuginfo.nix)
#
# Open a dump (no root needed if the dump is readable):
#   drgn -c /var/crash/<stamp>/dump.<stamp> -s /etc/gir-debuginfo/kernel/vmlinux \
#        --extra-symbols /etc/gir-debuginfo/zfs/zfs.ko.debug
# `drgn-crash` accepts crash-style commands (bt, ps, ...) on top of the same data.
{ config, pkgs, ... }:

let
  libkdumpfile = pkgs.callPackage ../pkgs/libkdumpfile.nix { };
  drgn = pkgs.callPackage ../pkgs/drgn.nix { inherit libkdumpfile; };
in
{
  environment.systemPackages = [ drgn ];

  # Kept with the generation so the debug info always matches the kernel that
  # is running (and the one the crash kernel boots).
  environment.etc."gir-debuginfo/kernel".source = config.boot.kernelPackages.kernel.dev;
}
