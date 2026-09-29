# Ticket 24 — kdump: the capture half, hand-rolled.
#
# ---------------------------------------------------------------------------
# Why not `boot.crashDump.enable`
# ---------------------------------------------------------------------------
# nixpkgs' boot.crashDump does two of the three things kdump needs: it reserves
# memory and it kexec-loads a capture kernel. The third — saving the dump — it
# hands to a human: it appends `1 boot.shell_on_fail` and leaves you in a systemd
# rescue shell, expecting someone at a console to copy /proc/vmcore by hand. gir
# is headless with `kernel.panic = 10`, so that yields nothing at all. It also
# hardcodes crashkernel=128M plus nmi_watchdog=panic and softlockup_panic=1,
# none of which match this host. So: reservation, load and capture are all
# written out below, and boot.crashDump stays off.
#
# ---------------------------------------------------------------------------
# The decision: package makedumpfile (chosen) vs. a raw `cp /proc/vmcore`
# ---------------------------------------------------------------------------
# makedumpfile is not in nixpkgs at any revision, so the alternative was a
# capture unit that just copies /proc/vmcore raw. The numbers decided it:
#
#   * gir has 123 GiB of RAM. A raw /proc/vmcore is essentially all of it.
#     Ubuntu's makedumpfile output for the same machine is 16–21 GiB
#     (2026-09-15: 20.9 GiB; 2026-09-19: 16.4 GiB) — a 6–8x reduction.
#   * /var/crash lives on rpool, which has ~1.2 TiB free and is shared with
#     everything else on the host. Three raw dumps would be ~370 GiB; this host
#     crashed three times in the five days before this was written.
#   * Every minute spent writing is a minute gir is down, from a 2 GiB capture
#     kernel running on one CPU. ~120 GiB of writes is the wrong shape for that.
#   * The whole point of the dumps is to feed `crash`, and `crash` reads the
#     kdump-compressed format natively. Nothing is lost.
#
# The cost is a hand-written derivation for an out-of-tree package: it is not in
# the binary cache, so it builds from source (a few seconds — one C program),
# and it must be kept current by hand. That is a small, bounded price against
# 100 GiB per crash. The derivation is kept in this file rather than in
# flake.nix's overlay so ticket 24 owns one file; lift it into the overlay if a
# second consumer ever appears.
#
# The raw copy survives as the *fallback* inside the capture script, exactly as
# Ubuntu's kdump-tools does it — if makedumpfile fails on a novel kernel
# structure, a giant raw vmcore still beats no vmcore.
#
# ---------------------------------------------------------------------------
# Ubuntu parity notes (read off gir 2026-09-19)
# ---------------------------------------------------------------------------
#   /proc/cmdline .......... crashkernel=2G,high
#   KDUMP_COREDIR .......... /var/crash            (ticket 07: rpool/srv/crash)
#   MAKEDUMP_ARGS .......... "-F -c -d 31"         (kdump-config forces -F)
#   KDUMP_CMDLINE_APPEND ... reset_devices systemd.unit=kdump-tools-dump.service
#                            nr_cpus=1 irqpoll nousb
#   KDUMP_NUM_DUMPS ........ 0 (unset) — nothing is ever purged. Kept as-is.
#   layout ................. /var/crash/YYYYMMDDHHMM/{dump.<stamp>,dmesg.<stamp>}
#
# Two deliberate deviations from Ubuntu:
#   * `-F` (flatten) is dropped. Ubuntu needs it because it pipes makedumpfile
#     through an optional compressor; we write straight to a file, so we get the
#     plain kdump-compressed format instead of one that needs makedumpfile-R.pl
#     to rearrange. (makedumpfile-R.pl is still installed, to re-read the
#     Ubuntu-era flattened dumps already sitting on the shared dataset.)
#   * `rd.systemd.unit=initrd.target` is appended. See the trap below.
#
# The panic *triggers* (kernel.panic_on_oops=1, kernel.hung_task_panic=1,
# kernel.panic=10, from /etc/sysctl.d/99-gir-hang-visibility.conf) are not set
# here — they belong to the sysctl port. Without them this module still captures
# an explicit panic, but nothing will trigger on a hung task.
{ config, lib, pkgs, ... }:

let
  coreDir = "/var/crash";

  makedumpfile = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "makedumpfile";
    version = "1.7.9";

    src = pkgs.fetchFromGitHub {
      owner = "makedumpfile";
      repo = "makedumpfile";
      rev = finalAttrs.version;
      hash = "sha256-Ktp+tYCFhL9UbkKLe2SRluqOF8B9n/s+WDRqvufGPEE=";
    };

    # perl only so that fixupPhase can patch makedumpfile-R.pl's shebang.
    nativeBuildInputs = [ pkgs.perl ];
    buildInputs = with pkgs; [ elfutils zlib bzip2 lzo ];

    # LINKTYPE=dynamic: upstream defaults to a fully static link, which wants
    # static libdw/libelf that nixpkgs does not ship by default. The capture
    # kernel boots this same closure with /nix mounted (neededForBoot), so a
    # dynamic binary is fine there.
    # USELZO=on / USESNAPPY unset matches Ubuntu's build ("lzo enabled,
    # snappy disabled" per `makedumpfile -v` on the host).
    makeFlags = [
      "LINKTYPE=dynamic"
      "USELZO=on"
      "CC=${pkgs.stdenv.cc.targetPrefix}cc"
    ];

    # Upstream's install target hardcodes ${DESTDIR}/usr/share/man/...; only
    # SBINDIR is parameterised.
    installFlags = [
      "DESTDIR=${placeholder "out"}"
      "SBINDIR=/bin"
    ];

    postInstall = ''
      mkdir -p $out/share
      mv $out/usr/share/* $out/share/
      rmdir $out/usr/share $out/usr
    '';

    enableParallelBuilding = true;

    meta = {
      description = "VMcore extraction tool (out-of-tree: not packaged in nixpkgs)";
      homepage = "https://github.com/makedumpfile/makedumpfile";
      license = lib.licenses.gpl2Only;
      mainProgram = "makedumpfile";
      platforms = lib.platforms.linux;
    };
  });

  # Runs in the *crash* kernel, after it has booted this same NixOS closure with
  # systemd.unit= pointing here.
  captureScript = pkgs.writeShellScript "kdump-capture" ''
    set -u

    if [ ! -e /proc/vmcore ]; then
      echo "kdump-capture: no /proc/vmcore — not a crash kernel, nothing to do"
      exit 0
    fi

    # Memory state of the crash kernel itself, onto netconsole: the two failed
    # captures of 2026-09 died of crash-kernel OOM, and this is the line that
    # says whether the next one is heading the same way.
    echo "kdump-capture: $(tr -s ' ' < /proc/meminfo | grep -E '^(MemFree|MemAvailable):' | tr '\n' ' ')min_free_kbytes=$(cat /proc/sys/vm/min_free_kbytes) arc_c_max=$(awk '$1 == "c_max" { print $3 }' /proc/spl/kstat/zfs/arcstats)"

    stamp=$(date +%Y%m%d%H%M)
    dir=${coreDir}/$stamp
    mkdir -p "$dir" || exit 1

    core="$dir/dump.$stamp"
    tmp="$dir/dump-incomplete"

    echo "kdump-capture: makedumpfile -c -d 31 /proc/vmcore -> $core"
    if makedumpfile -c -d 31 /proc/vmcore "$tmp"; then
      mv "$tmp" "$core"
      echo "kdump-capture: saved $core"
    else
      echo "kdump-capture: makedumpfile failed, falling back to a raw copy" >&2
      rm -f "$tmp"
      core="$dir/vmcore.$stamp"
      tmp="$dir/vmcore-incomplete"
      if cp --sparse=always /proc/vmcore "$tmp"; then
        mv "$tmp" "$core"
        echo "kdump-capture: saved raw $core"
      else
        echo "kdump-capture: raw copy failed too; no dump for $stamp" >&2
        rm -f "$tmp"
      fi
    fi

    # Cheap, small, and the thing actually read first after a crash. Best effort.
    makedumpfile --dump-dmesg /proc/vmcore "$dir/dmesg.$stamp" \
      || echo "kdump-capture: --dump-dmesg failed; dmesg will be unavailable" >&2

    sync
    echo "kdump-capture: done, rebooting"
  '';

  # Runs in the crash kernel's initrd (kdump-netconsole below). Only the
  # initrd's own /bin is used (coreutils, kmod, mount, bash; no grep there):
  # boot.initrd.systemd.storePaths copies this file but not its closure, so a
  # store-path PATH would point at nothing.
  crashNetconsoleScript = pkgs.writeShellScript "kdump-netconsole" ''
    set -u
    PATH=/bin
    MAC=3c:ec:ef:7f:2a:96
    CFG=/sys/kernel/config/netconsole/misfit-crash
    log() { echo "kdump-netconsole: $*" > /dev/kmsg; }

    modprobe atlantic || log "modprobe atlantic failed"
    modprobe configfs 2>/dev/null || true
    modprobe netconsole || { log "modprobe netconsole failed"; exit 1; }
    [ -d /sys/kernel/config/netconsole ] \
      || mount -t configfs none /sys/kernel/config || { log "no configfs"; exit 1; }
    [ -d /sys/kernel/config/netconsole ] || { log "no netconsole configfs dir"; exit 1; }

    dev=
    for _ in $(seq 1 20); do
      for n in /sys/class/net/*; do
        [ "$(cat "$n/address" 2>/dev/null)" = "$MAC" ] && dev=''${n##*/}
      done
      [ -n "$dev" ] && break
      sleep 1
    done
    [ -n "$dev" ] || { log "no interface with $MAC"; exit 1; }

    mkdir -p "$CFG" || exit 1
    echo "$dev"              > "$CFG/dev_name"
    echo 192.168.42.8        > "$CFG/local_ip"
    echo 192.168.42.1        > "$CFG/remote_ip"
    echo a0:36:9f:fb:67:94   > "$CFG/remote_mac"
    echo 6666                > "$CFG/local_port"
    echo 6666                > "$CFG/remote_port"
    # netpoll brings the link up itself and waits up to carrier_timeout.
    for _ in 1 2 3; do
      echo 1 > "$CFG/enabled" 2>/dev/null && break
      sleep 2
    done
    log "armed on $dev (enabled=$(cat "$CFG/enabled")), cmdline: $(cat /proc/cmdline)"
  '';

  # Runs in the crash kernel's initrd (kdump-stage1-watchdog below). The other
  # half of the rpool switch: panic-on-fail covers an import that FAILS, this
  # covers one that HANGS (zio suspended on a dead device never errors out).
  # sysrq-c rather than a reboot so the panic, and why, lands on netconsole.
  stage1WatchdogScript = pkgs.writeShellScript "kdump-stage1-watchdog" ''
    PATH=/bin
    sleep 1200
    echo "kdump-stage1-watchdog: crash kernel still in stage 1 after 20 min; panicking to reboot" > /dev/kmsg
    echo c > /proc/sysrq-trigger
  '';

  # Stage 2's counterpart (kdump-stage2-watchdog below). Capture is allowed
  # 60 min (kdump-capture's TimeoutStartSec), so 75 min is only ever a stuck
  # stage 2 — on 2026-09-29 an emergency shell that sat for 38 min until a
  # human rebooted it.
  stage2WatchdogScript = pkgs.writeShellScript "kdump-stage2-watchdog" ''
    sleep 4500
    echo "kdump-stage2-watchdog: crash kernel still in stage 2 after 75 min; panicking to reboot" > /dev/kmsg
    echo c > /proc/sysrq-trigger
  '';

  # Runs in the normal kernel: arms the crash kernel.
  loadScript = pkgs.writeShellScript "kdump-load" ''
    set -eu

    sys=$(readlink -f /run/current-system)

    # Reuse the running generation's own parameters rather than /proc/cmdline,
    # so a `nixos-rebuild switch` without a reboot arms the *new* closure. Drop
    # crashkernel= (the crash kernel must not reserve a second region) and any
    # hugepage reservations, matching kdump-config's own sed.
    params=$(tr '\n' ' ' < "$sys/kernel-params" \
      | sed -re 's/(^| )(crashkernel|hugepages|hugepagesz)=[^ ]*//g')

    # TRAP: systemd honours `systemd.unit=` in the initrd as well as in stage 2,
    # and NixOS 26.05 uses systemd stage 1. Left alone, the line below would
    # make the initrd try to boot kdump-capture.service — a unit that does not
    # exist there — and the crash kernel would never reach the real root. The
    # trailing `rd.systemd.unit=initrd.target` is only honoured inside the
    # initrd and comes last, so stage 1 gets its normal default and stage 2 gets
    # the capture unit. Do not reorder these two.
    #
    # zfs_arc_max is clamped because the crash kernel has 2 GiB total and still
    # has to import a 3.6 TiB pool to reach /var/crash.
    append="init=$sys/init"
    append="$append nr_cpus=1 reset_devices irqpoll nousb panic=10"
    append="$append zfs.zfs_arc_max=134217728"
    # Witness for the crash kernel itself (see kdump-netconsole below). The
    # inherited loglevel=4 would hide everything but warnings; the later
    # loglevel= wins. devkmsg=on stops /dev/kmsg ratelimiting userspace, and the
    # two systemd.* flags route PID 1 and every unit's output (makedumpfile,
    # the pool import) into the kernel log, hence onto netconsole.
    # carrier_timeout: the Aquantia 10G link needs longer than netpoll's 4 s.
    append="$append loglevel=7 printk.devkmsg=on netpoll.carrier_timeout=15"
    append="$append systemd.log_target=kmsg systemd.journald.forward_to_kmsg=1"
    append="$append systemd.unit=kdump-capture.service"
    append="$append rd.systemd.unit=initrd.target"
    # The rpool switch. rpool imports -> stage 2 -> kdump-capture -> reboot.
    # rpool does not (2026-09-23: both PNYs latched up, and kexec does not
    # power-cycle them) -> the initrd reaches emergency.target, and nixpkgs'
    # panic-on-fail.service, gated on exactly this flag, sysrq-crashes the
    # crash kernel; panic=10 above turns that into a reboot. Before this the
    # crash kernel sat in a locked emergency shell for 5 h. A reboot does not
    # revive latched-up drives either, but it gets the next boot's own
    # netconsole lines instead of silence. Crash kernel only: a normal boot
    # that fails keeps its emergency shell (emergencyAccess, configuration.nix).
    append="$append boot.panic_on_fail"
    # Host sysctls stay out of the crash kernel. Stage 2 would otherwise run
    # systemd-sysctl and apply vm.min_free_kbytes=2GiB (sysctl.nix), a watermark
    # above what the 2 GiB crash kernel has free: on 2026-09-27 udevadm was
    # OOM-killed 1.3 s after switch-root, then "System is deadlocked on
    # memory", and kdump-capture never started. Capture needs none of them.
    append="$append systemd.mask=systemd-sysctl.service"

    echo "kdump-load: kexec -p $sys/kernel"
    exec kexec -p \
      --initrd="$sys/initrd" \
      --command-line="$params $append" \
      "$sys/kernel"
  '';
in
{
  # Exactly Ubuntu's reservation. ",high" matters: 2 GiB cannot be found below
  # 4 GiB on this box, and a bare `crashkernel=2G` fails the reservation
  # silently at boot ("crashkernel reservation failed" in dmesg).
  boot.kernelParams = [ "crashkernel=2G,high" ];

  # Explicitly off — see the header.
  boot.crashDump.enable = false;

  # `crash` on the host reads these; makedumpfile is wanted interactively too
  # (e.g. re-filtering an existing dump, or makedumpfile-R.pl on the Ubuntu-era
  # flattened dumps already in /var/crash).
  environment.systemPackages = [ makedumpfile pkgs.kexec-tools ];

  warnings = lib.optional (!(builtins.hasAttr coreDir config.fileSystems))
    "kdump.nix: fileSystems.\"${coreDir}\" is not declared, so kdump-capture.service has no mount to depend on. Ticket 07 owns rpool/srv/crash -> ${coreDir}.";

  systemd.services.kdump-load = {
    description = "Load the kdump crash kernel";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.kexec-tools pkgs.coreutils pkgs.gnused ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${loadScript}";
      ExecStop = "${pkgs.kexec-tools}/bin/kexec -p -u";
      StandardOutput = "journal+console";
    };
  };

  # /run/current-system is re-pointed by `nixos-rebuild switch`; re-arm so the
  # loaded crash kernel is never a generation behind the running one.
  #
  # The path unit triggers kdump-rearm, not kdump-load itself. kdump-load is
  # RemainAfterExit and so already active, and a path unit only *starts* its
  # unit: starting an active unit does nothing. Until 2026-09-28 the path
  # pointed straight at kdump-load, and a switch at 21:49:49 left the crash
  # kernel armed with the boot generation. Only reboots ever re-armed it.
  systemd.services.kdump-rearm = {
    description = "Reload the kdump crash kernel for the new system generation";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.systemd.package}/bin/systemctl restart kdump-load.service";
    };
  };

  systemd.paths.kdump-load = {
    description = "Re-arm the kdump crash kernel when the system generation changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/run/current-system";
      Unit = "kdump-rearm.service";
    };
  };

  # ---------------------------------------------------------------------------
  # Crash-kernel witness: netconsole from stage 1.
  # ---------------------------------------------------------------------------
  # 2026-09-23: the crash kernel ran for ~3 min and left nothing — no dump, no
  # journal, no netconsole — because netconsole.nix arms the target from a
  # stage-2 unit that the capture boot never starts. This arms the same misfit
  # target from inside the initrd, only when /proc/vmcore exists, so the pool
  # import, the switch-root and the capture itself are all on misfit's log.
  # The configfs target survives switch-root, so stage 2 is covered too.
  #
  # Why not `netconsole=` on the command line: the module takes a device *name*,
  # and in stage 1 udev may or may not have renamed the Aquantia port to eno1
  # yet. Matching the MAC is race-free. local_ip is given outright because
  # nothing configures addresses in the initrd (netpoll does not need one on
  # the interface). Values from netconsole.nix / /sys/kernel/config 2026-09-22.
  # Cost on a normal boot: atlantic/netconsole/configfs sit in the initrd, and
  # udev loads atlantic a little earlier than before. Nothing else runs.
  boot.initrd.availableKernelModules = [ "atlantic" "configfs" "netconsole" ];
  boot.initrd.systemd.storePaths = [ crashNetconsoleScript stage1WatchdogScript ];
  boot.initrd.systemd.services.kdump-netconsole = {
    description = "Arm netconsole to misfit in the kdump crash kernel";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "zfs-import-rpool.service" "sysroot.mount" ];
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "/proc/vmcore";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${crashNetconsoleScript}";
      # Never let the witness hold up the dump.
      TimeoutStartSec = "60s";
    };
  };

  # A normal crash-kernel stage 1 took ~1 min on 2026-09-23 (06:16:46 up,
  # 06:17:50 import result), so 20 min is only ever a hang. Type=simple so it
  # never holds up initrd.target; like any initrd service without
  # IgnoreOnIsolate it is stopped when initrd-switch-root.target is isolated,
  # so it can never fire during the stage-2 capture (that has its own 60 min
  # timeout, and kdump-stage2-watchdog behind it).
  boot.initrd.systemd.services.kdump-stage1-watchdog = {
    description = "Reboot the kdump crash kernel if stage 1 hangs";
    wantedBy = [ "initrd.target" ];
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "/proc/vmcore";
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${stage1WatchdogScript}";
    };
  };

  systemd.services.kdump-capture = {
    description = "Save /proc/vmcore after a crash";

    # Deliberately not wantedBy anything: it is reached only by
    # systemd.unit=kdump-capture.service on the crash kernel's command line.
    #
    # No default dependencies: capture needs /var/crash and nothing else. With
    # them, sysinit.target pulled in local-fs.target and so every host mount.
    # On 2026-09-29 the crash kernel never imported bank7 (only rpool in stage 1
    # and vmpool for /home/myers/p), so /dev/zvol/bank7/dropbox never appeared.
    # /srv/dropbox (no nofail, storage.nix) timed out after 10 min,
    # local-fs.target failed into emergency.target, and the isolate cancelled
    # this job. No vmcore. Skipping sysinit also skips udev coldplug over ~20
    # disks, the process the 2026-09-27 crash-kernel OOM killed first.
    #
    # /var/crash is rpool/srv/crash, and rpool is imported in stage 1.
    # journald: StandardOutput below goes through its socket.
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "/proc/vmcore";
      RequiresMountsFor = coreDir;
    };
    wants = [ "systemd-journald.socket" "kdump-stage2-watchdog.service" ];
    after = [ "systemd-journald.socket" ];

    path = [ makedumpfile pkgs.coreutils pkgs.gnugrep pkgs.gawk ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${captureScript}";
      # Whether the dump succeeded, failed or timed out, the machine must come
      # back. This is Ubuntu's KDUMP_FAIL_CMD default ("reboot -f") applied to
      # every exit path.
      ExecStopPost = "${config.systemd.package}/bin/systemctl --force --force reboot";
      # 123 GiB of RAM through one CPU: Ubuntu's own captures took ~6 minutes,
      # and the raw fallback is several times that. The 90 s oneshot default
      # would kill every real dump.
      TimeoutStartSec = "60min";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  # kdump-capture's ExecStopPost reboots only if the capture *ran*. A job that
  # never starts (dependency failed, or cancelled by an isolate to emergency,
  # as on 2026-09-29) reboots nothing, and stage 1's watchdog is already gone.
  # IgnoreOnIsolate so emergency.target cannot stop this one too. Pulled in
  # only by kdump-capture, which only the crash kernel's command line starts.
  systemd.services.kdump-stage2-watchdog = {
    description = "Reboot the kdump crash kernel if stage 2 hangs";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "/proc/vmcore";
      IgnoreOnIsolate = true;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${stage2WatchdogScript}";
    };
  };
}
