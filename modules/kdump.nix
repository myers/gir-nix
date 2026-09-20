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
    append="$append systemd.unit=kdump-capture.service"
    append="$append rd.systemd.unit=initrd.target"

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
  systemd.paths.kdump-load = {
    description = "Re-arm the kdump crash kernel when the system generation changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/run/current-system";
      Unit = "kdump-load.service";
    };
  };

  systemd.services.kdump-capture = {
    description = "Save /proc/vmcore after a crash";

    # Deliberately not wantedBy anything: it is reached only by
    # systemd.unit=kdump-capture.service on the crash kernel's command line.
    # Default dependencies pull in sysinit/local-fs, which is what brings up
    # ZFS and therefore /var/crash.
    unitConfig = {
      ConditionPathExists = "/proc/vmcore";
      RequiresMountsFor = coreDir;
    };

    path = [ makedumpfile pkgs.coreutils ];

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
}
