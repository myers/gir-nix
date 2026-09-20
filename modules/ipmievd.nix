# Ticket 24 — ipmievd, the IPMI event daemon.
#
# No NixOS module exists for it (services.ipmi covers the kernel side only —
# device nodes and the watchdog — not ipmievd), so this is the Ubuntu unit
# transcribed. Ubuntu's copy, verbatim:
#
#   # /lib/systemd/system/ipmievd.service
#   [Unit]
#   Description=IPMI event daemon
#   After=openipmi.service
#   [Service]
#   Type=forking
#   ExecStart=/usr/sbin/ipmievd open daemon
#   [Install]
#   WantedBy=multi-user.target
#   Alias=ipmi.service
#
# Arguments are unchanged: `open` selects the OpenIPMI kernel interface
# (/dev/ipmi0, via ipmi_devintf), `daemon` forks into the background — hence
# Type=forking. It writes SEL events to syslog; on gir that is the only thing
# turning a BMC-logged ECC or thermal event into something the journal shows.
#
# `After=openipmi.service` has no NixOS counterpart: Ubuntu's openipmi.service
# is the module-loading shim. Here boot.kernelModules does that job, so the unit
# is ordered after systemd-modules-load.service and simply waits for /dev/ipmi0.
{ config, lib, pkgs, ... }:

{
  # Ticket 05 names these three explicitly. Live on gir, lsmod also shows
  # ipmi_ssif and acpi_ipmi; both are autoloaded off ACPI/SMBIOS and are not
  # listed here on purpose — ipmi_si is the interface ipmievd actually uses.
  boot.kernelModules = [ "ipmi_si" "ipmi_devintf" "ipmi_msghandler" ];

  # ipmitool itself is used interactively and by the sensor-log/textfile
  # collectors; Ubuntu has it at /usr/bin/ipmitool.
  environment.systemPackages = [ pkgs.ipmitool ];

  systemd.services.ipmievd = {
    description = "IPMI event daemon";

    after = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];

    # The device is created by ipmi_devintf once ipmi_si has probed the BMC;
    # that can lag the module load slightly.
    unitConfig.ConditionPathExists = "/dev/ipmi0";

    serviceConfig = {
      Type = "forking";
      # Upstream ipmitool installs ipmievd as sbin_PROGRAMS, so it lands in
      # $out/sbin — the same split Debian ships (/usr/bin/ipmitool,
      # /usr/sbin/ipmievd). nixpkgs applies no patch that changes this.
      # TODO(collect): confirm before the first switch:
      #   nix build --no-link --print-out-paths \
      #     github:NixOS/nixpkgs/c3eea5b2156db11c7eeeada3dc737711255b253e#ipmitool \
      #     | xargs -I{} ls {}/sbin {}/bin
      ExecStart = "${pkgs.ipmitool}/sbin/ipmievd open daemon";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
}
