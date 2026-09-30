# DWARF for the zfs kernel module, kept out of the running module.
#
# nixpkgs strips zfs.ko / spl.ko to a bare symbol table. `drgn` (and `crash`)
# then cannot read kmutex_t, arc_buf_hdr_t or buf_hash_table_t, which is exactly
# what finding an ARC hash-lock holder in a vmcore needs (logs/vmcore-hashlock-
# owners-20260918-101911.sh did this on Ubuntu, where dbgsym packages existed).
#
# One build, two results, like a distro dbgsym package: the module that loads
# is the same stripped size as stock (a 105 MB .ko would bloat the initrd and
# the 2 GiB crash kernel, which has OOM'd before), and the DWARF goes to a
# separate `debug` output. Both come from the same link, so their GNU
# build-ids match and a debugger can pair them.
#
# Only the kernel module is rebuilt: userland and the on-disk format are stock
# 2.3.9, so zfs.nix's version assertion (modulePackage.version ==
# package.version) still holds. Cost: one local build (not in the binary cache).
# Runtime behaviour is unchanged; --enable-debuginfo only adds -g.
#
# On the host the DWARF is at /etc/gir-debuginfo/zfs/{zfs,spl}.ko.debug, with
# the matching build-ids beside it in {zfs,spl}.ko.build-id.
{ config, pkgs, ... }:

let
  mod = config.boot.zfs.modulePackage;
in
{
  boot.zfs.modulePackage =
    (config.boot.kernelPackages.${config.boot.zfs.package.kernelModuleAttribute}).overrideAttrs
      (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [ "--enable-debuginfo" ];
        outputs = (old.outputs or [ "out" ]) ++ [ "debug" ];
        # Runs before nixpkgs' own postBuild, which does `strip --strip-debug`
        # (strip hooks skip the compressed modules, so it strips pre-compression).
        postBuild = ''
          mkdir -p $debug
          # Only the two real modules: configure leaves ~190 probe .ko files behind.
          for ko in $(find . -name zfs.ko -o -name spl.ko); do
            n=$(basename $ko)
            ${pkgs.binutils}/bin/objcopy --only-keep-debug $ko $debug/$n.debug
            ${pkgs.binutils}/bin/readelf -n $ko | sed -n 's/.*Build ID: //p' > $debug/$n.build-id
          done
        '' + (old.postBuild or "");
      });

  # Pin the debug output into the system closure so it is built with the
  # generation and survives gc while the generation is kept.
  environment.etc."gir-debuginfo/zfs".source = mod.debug;
}
