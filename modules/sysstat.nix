{ pkgs, ... }:
{
  ############################################################################
  ## sysstat (sar) -- the run-up recorder
  ##
  ## Ubuntu had this and the incident analyses leaned on it: /var/log/sysstat/sa27
  ## is evidence in the 2026-08-27 namespace_sem writeup, and "no 08:04 sysstat
  ## sample" dates the silent stop on 2026-09-18. hygiene.nix assumed it "arrives
  ## with its own module"; nothing enabled it, so NixOS ran from the 2026-09-20
  ## cutover with no sar at all. Netconsole and kdump catch the moment of death;
  ## this is what shows the twenty minutes before it, and it survives reboots,
  ## which a backgrounded sampler script does not.
  ##
  ## It is also the recorder for the soak's pass criterion (nixos-migration map,
  ## "Soak acceptance criteria", decided 2026-09-20): 21 days AND at least one
  ## memory-pressure episode the host survives. sadc records PSI, so
  ## `sar -q MEM` / `sar -q IO` answer "was there pressure, and when"; OOM kills
  ## come from the journal.
  ##
  ## Every 2 minutes rather than the stock 10: on 2026-09-18 CI pods started at
  ## 07:22 and ZFS stopped at ~07:34, so a 10-minute grid put one sample in the
  ## whole run-up. `-S DISK` matches Ubuntu's SADC_OPTIONS. HISTORY=28 covers
  ## the soak and is the largest value that keeps sa2's flat /var/log/sa layout
  ## (above 28 it switches to YYYYMM subdirectories). /var/log is
  ## rpool/nixos/log: persistent, and snapshotted by sanoid.
  ############################################################################
  services.sysstat = {
    enable = true;
    collect-frequency = "*:0/2";
    collect-args = "1 1";
  };

  # sa1/sa2 read /etc/sysconfig/sysstat, not /etc/sysstat (checked in the 12.7.7
  # scripts). Without this file sa1 falls back to HISTORY=0 and SADC_OPTIONS="".
  environment.etc."sysconfig/sysstat".text = ''
    HISTORY=28
    COMPRESSAFTER=29
    SADC_OPTIONS="-S DISK"
  '';

  # The module starts the collectors but does not put sar on PATH.
  environment.systemPackages = [ pkgs.sysstat ];
}
