# Ticket 24 — kernel tunables: the panic triggers, the memory headroom, and the
# ARC cap.
#
# This module is the other half of `kdump.nix`. kdump.nix builds the capture
# path; nothing here fires it, and without what is in here kdump.nix only ever
# catches an *explicit* panic. The class of failure gir actually suffers —
# eight whole-box wedges between 2026-08-10 and 2026-09-15 — is a hung task, not
# an oops, and a hung task produces a dump only because `kernel.hung_task_panic`
# is set. That single line is the reason `/var/crash/202609151957/` exists.
#
# Everything here was read off the live Ubuntu host on 2026-09-19. Ubuntu's own
# `/etc/sysctl.d/10-*.conf` files are distro defaults and are deliberately NOT
# carried: NixOS has its own equivalents or its own kernel defaults, and copying
# Ubuntu's would freeze a foreign distro's policy into this host. The two that
# Ubuntu's own 99-* files override (`kernel.printk`, `kernel.sysrq`) are carried
# at their *overridden* values, which is what the box actually runs.
#
# Provenance of every value, so this can be re-derived:
#
#   /etc/sysctl.d/99-gir-hang-visibility.conf   (from ansible, 2026-08-29)
#     kernel.hung_task_warnings, kernel.printk, kernel.sysrq,
#     kernel.hung_task_timeout_secs, kernel.hung_task_panic
#   /etc/sysctl.d/99-gir-memory.conf            (from ansible, 2026-08-30)
#     vm.min_free_kbytes
#   /etc/sysctl.d/99-gir-swap-pressure.conf     (apply-memory-pressure-mitigations.sh, 2026-09-15)
#     vm.swappiness
#   /etc/sysctl.d/99-megacmd-inotify-limit.conf (2022)
#     fs.inotify.max_user_watches
#   /etc/sysctl.conf  (symlinked as /etc/sysctl.d/99-sysctl.conf)
#     fs.inotify.max_user_instances (the ipv6 block in the same file belongs
#     to networking.nix)
#   NOT in any file on Ubuntu — live-only, and therefore lost on every reboot:
#     kernel.panic_on_oops = 1   set imperatively by Debian's `kdump-config`
#                                (`sysctl -w kernel.panic_on_oops=1`, line 443)
#                                every time the crash kernel is loaded
#     kernel.panic = 10          provenance unknown; the Ubuntu kernel ships
#                                CONFIG_PANIC_TIMEOUT=0 and nothing under /etc
#                                or in this repo sets it. It was almost
#                                certainly set by hand during an incident.
#   Making those last two declarative is a deliberate *improvement* over the
#   Ubuntu side, not a transcription: kdump.nix's header already assumes both
#   are set, and on Ubuntu neither survives a boot without kdump-config running.
{ ... }:

{
  ############################################################################
  ## Panic triggers — what actually makes kdump fire.
  ##
  ## Read kdump.nix before changing any of these. `kernel.hung_task_panic`
  ## without a loaded crash kernel converts a wedge into a plain reboot with no
  ## dump at all, which is strictly worse than a wedge you can photograph from
  ## the BMC. Check `kexec_crash_loaded` before relying on it.
  ############################################################################
  boot.kernel.sysctl = {
    # A hung task panics instead of wedging indefinitely. This is the ONLY
    # thing that names the task *holding* the lock: the holder is not itself
    # blocked, so it never shows up in a hung-task report — which is why three
    # postmortems in a row failed to identify it.
    "kernel.hung_task_panic" = 1;

    # 300s, not the 120s default, to cut false positives: a legitimately slow
    # operation on a 6-pool ZFS box can block for minutes. All the observed
    # lockups ran 22–109 minutes, so 300s catches them with room to spare.
    "kernel.hung_task_timeout_secs" = 300;

    # hung_task_warnings is a PER-BOOT BUDGET, not a rate limit. The default of
    # 10 is spent on the first burst and never replenished; the 2026-08-27
    # lockup silently disabled its own hang detector 12h48m before the fatal
    # hang. -1 = unlimited. With this set, 2026-08-28 produced 443 trace lines
    # instead of 10.
    "kernel.hung_task_warnings" = -1;

    # Panic on oops rather than limping on with a corrupt task. Ubuntu got this
    # only as a side effect of kdump-config; here it is declarative.
    "kernel.panic_on_oops" = 1;

    # Reboot 10s after a panic. Relevant only when the crash kernel is NOT
    # loaded — when it is, the kexec happens first and kdump.nix's capture
    # kernel carries its own `panic=10`. Without this a headless box that
    # panics before kdump is armed just sits there.
    "kernel.panic" = 10;

    # console_loglevel 4 drops KERN_WARNING, which is where Call Trace and
    # SCSI/ATA timeouts live — netconsole never saw them. 7 lets them through.
    # This is the value from 99-gir-hang-visibility.conf, which overrides
    # Ubuntu's 10-console-messages.conf (`4 4 1 7`). It also overrides NixOS'
    # own default, which is `mkDefault config.boot.consoleLogLevel` (4).
    # netconsole.nix is the consumer; see 2026-08-30-gir-crash.md.
    "kernel.printk" = "7 4 1 7";

    # sysrq: manual crash/sync/reboot from the BMC serial console during a
    # wedge. 184 = 128 (reboot/poweroff) + 32 (remount-ro) + 16 (sync)
    #             + 8 (debug dumps). From 99-gir-hang-visibility.conf, which
    # overrides Ubuntu's 10-magic-sysrq.conf (176 — the same set without the
    # debug dumps).
    "kernel.sysrq" = 184;

    ##########################################################################
    ## Memory headroom.
    ##########################################################################

    # The kernel auto-sizes min_free_kbytes as 4*sqrt(lowmem) and then CAPS it
    # at 64 MB regardless of RAM, so this 123 GB box defaults to ~66 MB. That
    # is far too little to keep GFP_ATOMIC callers alive through a reclaim
    # storm — on 2026-08-30 both the atlantic NIC's RX path and ZFS's z_wr_iss
    # threads failed order-0 atomic allocations at the same moment. 2 GiB.
    "vm.min_free_kbytes" = 2097152;

    # The 2026-09-15 panic was a reclaim/swap-write deadlock: 710 tasks stuck
    # in mempool_alloc under raid1_write_request, swapping to the md0 RAID1.
    # Fewer swap writes means fewer chances to hit it. 60 is the default and
    # far too eager for a box whose swap write path is the failure mode.
    "vm.swappiness" = 10;

    ##########################################################################
    ## Host-added limits carried verbatim.
    ##########################################################################

    # /etc/sysctl.d/99-megacmd-inotify-limit.conf — megacmd, and since then
    # syncthing and the CI checkouts, exhaust the 8192 default.
    "fs.inotify.max_user_watches" = 524288;

    # /etc/sysctl.conf
    "fs.inotify.max_user_instances" = 524288;

    # NOT here, on purpose: `net.ipv6.conf.{all,default,lo}.disable_ipv6 = 1`
    # (the "death to ipv6" block at the bottom of /etc/sysctl.conf) and
    # `net.ipv4.conf.{all,default}.rp_filter = 2`. networking.nix owns the
    # networking sysctls and already sets all five. This is not a stylistic
    # split — `boot.kernel.sysctl` merges with `mergeOneOption`, so TWO
    # DEFINITIONS OF THE SAME KEY FAIL AT EVAL EVEN WHEN THE VALUES ARE
    # IDENTICAL. Anything network-shaped belongs in networking.nix, not here.
  };

  ############################################################################
  ## ARC sizing — /etc/modprobe.d/zfs.conf, ported.
  ##
  ## Why this is `boot.extraModprobeConfig` and not a sysctl or a kernel
  ## parameter:
  ##
  ##   * `zfs_arc_max` is a module parameter. It is read when the zfs module
  ##     loads, which on a ZFS-root box happens in the INITRD. Setting it only
  ##     in the running system is too late — that is precisely the failure gir
  ##     already had on Ubuntu: `/etc/modprobe.d/zfs.conf` said 24 GiB while a
  ##     stale copy baked into the initramfs said 16 GiB, and the initramfs
  ##     copy won at every boot (observed 2026-09-18). It took an
  ##     `update-initramfs` to fix.
  ##   * On NixOS that failure mode cannot recur. `boot.extraModprobeConfig`
  ##     produces `/etc/modprobe.d/nixos.conf` as a single store path, and the
  ##     *same store path* is what stage-1 and the systemd initrd copy in
  ##     (nixos/modules/system/boot/stage-1.nix:386 and
  ##     system/boot/systemd/initrd.nix:533). The initrd cannot go stale
  ##     relative to the system, because changing one changes the other's hash
  ##     and rebuilds the boot entry.
  ##   * `boot.kernelParams = [ "zfs.zfs_arc_max=..." ]` would also reach the
  ##     initrd, but it is invisible in `/etc/modprobe.d` and easy to lose in a
  ##     bootloader edit. modprobe.d is where the Ubuntu side keeps it, so a
  ##     side-by-side diff of the two OSes stays possible during the soak.
  ##
  ## 25769803776 = 24 GiB exactly, which is what the live host runs
  ## (/sys/module/zfs/parameters/zfs_arc_max, 2026-09-19).
  ##
  ## kdump.nix clamps the *capture* kernel to `zfs.zfs_arc_max=134217728` on
  ## its own command line; a kernel parameter beats modprobe.d, so these two do
  ## not fight.
  ############################################################################
  boot.extraModprobeConfig = ''
    # ARC sizing, to keep ZFS from starving the kernel of memory.
    #
    # Default is 0 = half of RAM = ~61.7 GB on this 123 GB box. Cap it so ARC
    # plus pod memory plus page cache fit with headroom. Matches the open
    # upstream issue openzfs/zfs#16978 (ZFS 2.2.2 on 6.8–6.11), where ARC keeps
    # ~50% of RAM and does not release it as higher-order pages run out.
    options zfs zfs_arc_max=25769803776

    # Caps how much the kernel shrinker may reclaim from ARC per call. The
    # default of 10000 pages (~39 MB) is the reason ARC cannot give memory back
    # fast enough during a burst. 0 removes the throttle.
    options zfs zfs_arc_shrinker_limit=0
  '';
}
