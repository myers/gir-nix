# gir: Samba file server (ticket 24, module 7).
#
# Ported from the live Ubuntu configuration collected on 2026-09-19:
#   logs/port-configs-20260919-182118/samba/{smb.conf,testparm.txt,pdbedit.txt,
#                                            shares.txt,state-dir.txt}
# The *effective* config (`testparm -s`) is the source of truth, not the raw
# smb.conf: the raw file has an "ANSIBLE MANAGED BLOCK" with a SECOND [global]
# section that overrides the first one. Most visibly, the first [global] allows
# 10.10.10.0/24 and the second does not — so the effective global `hosts allow`
# is the three-entry list below, and only the (now dropped) printer shares ever
# carried 10.10.10.0/24.
#
# Decisions implemented here; nothing in this file re-decides them:
#   * ticket 05 — CUPS (a snap) is dropped, and with it the `[printers]` and
#     `[print$]` shares. `[backups]` is dropped too: it points at
#     /bank4/backups and there is no `bank4` pool.
#   * ticket 05, "Port-time corrections" — `[things]` pointed at /stuff on
#     Ubuntu; it is corrected to /things here. See the TODO on that share.
#   * ticket 05 — Avahi is kept "+ explicit TM advertisement".
#   * ticket 07 item 17 — `rpool/srv/samba` → /var/lib/samba is SHARED with
#     Ubuntu. passdb.tdb and secrets.tdb (the machine SID) live there, so the
#     conditions are: same NetBIOS name, same workgroup, same user names and
#     UIDs, and NO usershares owned by nixpkgs' default `samba` group. tdb
#     formats are unchanged 4.15 → 4.23.
#   * ticket 14 — the host firewall is off, so `openFirewall` stays false;
#     smbd binds 192.168.42.8 only and must start after network-online.target
#     (nixpkgs' units already do: `after`/`wants` network-online.target).
#
# NOT declared here, on purpose:
#   * the /var/lib/samba fileSystems entry and the RequiresMountsFor wiring for
#     samba-smbd/nmbd/winbindd — storage.nix owns both.
#   * any user account — users.nix owns them. All five Samba accounts in
#     `pdbedit -L -v` (myers 1000, laura 1001, lillian 1002, arthur 1003,
#     zeke 1004) already exist there with matching UIDs, which is exactly what
#     ticket 07's "same user names and UIDs" requires.
#
# This nixpkgs revision (c3eea5b, 26.05) uses `services.samba.settings`, an
# attrset run through `pkgs.formats.ini`. `services.samba.extraConfig` and
# `services.samba.shares` are REMOVED/RENAMED there — verified against
# nixos/modules/services/network-filesystems/samba.nix in the pinned source.
{ lib, ... }:

let
  # Effective global `hosts allow`, from `testparm -s`. The ini generator is
  # configured with `listToValue = concatMapStringsSep " "`, so a list renders
  # space-separated, exactly as smb.conf wants it.
  hostsAllow = [
    "192.168.42.0/24"
    "192.168.2.0/24"
    "127.0.0.1"
  ];

  # The four Time Machine shares are identical apart from their path.
  timeMachineShare = user: {
    path = "/srv/timemachine/${user}";
    "read only" = "no";
    "inherit acls" = "yes";
    # Only these four shares load streams_xattr. Ticket 05: /other and
    # /srv/arthur_smb are deliberately `xattr=on acltype=off` while the four
    # timemachine datasets are `xattr=sa acltype=posix` — do NOT "fix" that.
    "vfs objects" = [
      "catia"
      "fruit"
      "streams_xattr"
    ];
    "fruit:time machine" = "yes";
  };

  timeMachineUsers = [
    "myers"
    "laura"
    "lillian"
    "arthur"
  ];
in
{
  ############################################################################
  ## Samba
  ############################################################################

  services.samba = {
    enable = true;

    # Ticket 14: `networking.firewall.enable = false` on this host, so this
    # option would be a no-op. Left explicitly false so that re-enabling the
    # firewall later does not silently open 139/445/137/138 on every interface
    # — smbd binds 192.168.42.8 only.
    openFirewall = false;

    smbd.enable = true;

    # `nmbd.service` is `enabled` on the live host and nmbd is listening on
    # udp/137 and udp/138 on 0.0.0.0, 192.168.42.8 and 192.168.42.255
    # (logs/privileged-audit-20260916-072444.txt). Ported.
    nmbd.enable = true;

    # winbindd is NOT installed or enabled on gir: it appears in neither the
    # unit list nor `ss -tulpn`, and the server role is ROLE_STANDALONE with no
    # domain membership. nixpkgs DEFAULTS THIS TO TRUE, so leaving it out would
    # start a daemon Ubuntu never ran — and would create winbindd state under
    # the shared /var/lib/samba dataset that Ubuntu knows nothing about.
    winbindd.enable = false;

    # NSS WINS needs winbindd; off, and asserted so by the module.
    nsswins = false;

    # Ticket 07 item 17: "no usershares with the default samba group".
    # Enabling this would (a) create a group literally named `samba` and
    # (b) chown /var/lib/samba/usershares to it via tmpfiles — on the dataset
    # SHARED with Ubuntu, where that directory is root:sambashare 1775 today.
    # Ubuntu's `usershare allow guests = yes` is deliberately not ported: with
    # `usershare max shares = 0` there are no usershares for it to apply to.
    usershares.enable = false;

    settings = {
      ######################################################################
      ## [global] — reproduced from `testparm -s`
      ######################################################################
      global = {
        # ticket 07 item 17. Ubuntu never set this, so Samba derived it from
        # the hostname: `pdbedit -L -v` shows `Domain: GIR` and home paths of
        # \\GIR\<user>. It is pinned explicitly here because the machine SID in
        # the shared secrets.tdb is bound to this name — if it changes, every
        # Mac sees a different server and Time Machine starts a fresh full
        # backup of 5.87 TiB.
        "netbios name" = "GIR";
        workgroup = "WORKGROUP";

        # Kept verbatim, "Ubuntu" and all: it is what clients display today,
        # and parity costs nothing here.
        "server string" = "%h server (Samba, Ubuntu)";

        "server role" = "standalone server";
        security = "user";

        ## Networking ------------------------------------------------------
        interfaces = [ "192.168.42.8" ];
        "bind interfaces only" = "yes";
        "hosts allow" = hostsAllow;

        ## Protocol floor/ceiling ------------------------------------------
        "server min protocol" = "SMB2";
        "server max protocol" = "SMB3";
        "client min protocol" = "SMB2";
        "client max protocol" = "SMB3";
        "client ipc min protocol" = "SMB2";
        "client ipc max protocol" = "SMB3";

        ## Authentication ---------------------------------------------------
        "map to guest" = "Bad User";
        "obey pam restrictions" = "yes";
        "pam password change" = "yes";
        "unix password sync" = "yes";
        # `passwd program` is deliberately NOT set: nixpkgs defaults it to
        # /run/wrappers/bin/passwd %u, which is the correct NixOS path for the
        # same shadow `passwd` that Ubuntu's /usr/bin/passwd is, and the chat
        # script below matches its prompts unchanged.
        #
        # An indented Nix string keeps the backslashes literal — smb.conf wants
        # the two characters \s and \n here, not whitespace.
        "passwd chat" = ''*Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .'';
        # nixpkgs defaults `invalid users` to [ "root" ]; Ubuntu set nothing.
        # The default is kept: root has no entry in passdb.tdb on either OS, so
        # this is strictly a belt-and-braces difference.

        ## Logging -----------------------------------------------------------
        # /var/log/samba is created by the nixpkgs module's tmpfiles rules.
        logging = "file";
        "log file" = "/var/log/samba/log.%m";
        "max log size" = 1000;
        # Ubuntu's `panic action = /usr/share/samba/panic-action %d` is NOT
        # ported: that path is Debian's, nixpkgs ships no equivalent script,
        # and a non-existent panic action is worse than none. smbd cores are
        # still collected through systemd-coredump (LimitCORE=infinity is set
        # by the unit).

        ## Printing — ticket 05 drops CUPS and both printer shares ------------
        # nixpkgs' `samba` is built with `enablePrinting = false`, but smbd
        # still probes a printcap at startup unless told not to. These three
        # lines are the only additions to the host's effective global section,
        # and they exist solely because the CUPS snap is gone.
        "load printers" = "no";
        printing = "bsd";
        "printcap name" = "/dev/null";
        "disable spoolss" = "yes";

        ## usershares --------------------------------------------------------
        # Explicit, fail-closed, per ticket 07 item 17 (see usershares.enable).
        "usershare max shares" = 0;

        ## idmap --------------------------------------------------------------
        "idmap config * : backend" = "tdb";

        ## vfs_fruit, global half --------------------------------------------
        # Verbatim from the host. testparm warns that some services use
        # vfs_fruit and others do not; that is true on Ubuntu today and stays
        # true here — only the four timemachine shares load the module.
        "fruit:metadata" = "stream";
        "fruit:model" = "MacSamba";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:nfs_aces" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";
      };

      ######################################################################
      ## Shares
      ##
      ## Dropped relative to the live host (all three by ticket 05):
      ##   [printers], [print$]  — with the CUPS snap
      ##   [backups]             — /bank4/backups, and there is no bank4 pool
      ##
      ## `directory mask` is omitted wherever the host's value was 0755, which
      ## is Samba's own default — `testparm -s` omits it for the same reason.
      ######################################################################

      # TODO(ticket 05, "Port-time corrections"): this share pointed at /stuff
      # on Ubuntu and the correction recorded there is that it should point at
      # /things (bank7/things, its own dataset). Applied here because the
      # correction is explicitly a *port-time* one. VERIFY BEFORE WINDOW B that
      # /things holds what clients of \\GIR\things expect; if it does not, this
      # line goes back to /stuff and the correction moves to a follow-up.
      things = {
        path = "/things";
        "read only" = "no";
        browseable = "no";
      };

      # Unlike [things], this one is read-only and genuinely points at /stuff.
      stuff = {
        path = "/stuff";
        "read only" = "yes";
        browseable = "no";
      };

      comics = {
        path = "/comics";
        "read only" = "no";
      };

      books = {
        path = "/books";
        "read only" = "no";
      };

      other = {
        path = "/other";
        "read only" = "no";
      };

      vital = {
        path = "/vital";
        "read only" = "no";
        "create mask" = "0644";
      };

      music = {
        path = "/music";
        "read only" = "no";
      };

      mmm = {
        path = "/mmm";
        "read only" = "no";
        "create mask" = "0644";
      };

      arthur_smb = {
        path = "/srv/arthur_smb";
        "read only" = "no";
        "create mask" = "0644";
        "valid users" = [ "arthur" ];
      };
    }
    # [timemachine_myers], [timemachine_laura], [timemachine_lillian],
    # [timemachine_arthur] — 5.87 TiB of live backups behind these four.
    // lib.listToAttrs (
      map (user: lib.nameValuePair "timemachine_${user}" (timeMachineShare user)) timeMachineUsers
    );
  };

  ############################################################################
  ## Avahi: the Time Machine advertisement (ticket 05)
  ##
  ## Two facts make this necessary rather than decorative:
  ##
  ##  1. Debian/Ubuntu build Samba WITH avahi support, so Ubuntu's smbd
  ##     registers _smb._tcp itself. nixpkgs' `samba` is built with
  ##     `enableMDNS ? false` (pkgs/servers/samba/4.x.nix:49) — only
  ##     `samba4Full` flips it, and that is an uncached source rebuild. So on
  ##     NixOS nothing registers mDNS unless it is declared here.
  ##  2. _adisk._tcp is what puts a share in Time Machine's disk picker, and
  ##     Samba never publishes it on either OS. Ticket 05 records the live
  ##     host's avahi-daemon as "keep natively, + explicit TM advertisement";
  ##     no _adisk._tcp service file was found in the collected config, so this
  ##     block is the explicit advertisement that ticket 05 asked for rather
  ##     than a transcription of an existing file.
  ##
  ## Avahi is not assigned to any module by ticket 24, and no other module in
  ## this tree touches `services.avahi`. It lives here because the shares it
  ## advertises live here. If an avahi.nix is ever written, move the daemon
  ## settings there and leave `extraServiceFiles.timemachine` behind.
  ##
  ## adVF=0x82 marks a share as a Time Machine destination; waMa=0 is the
  ## "no wide-area Bonjour" flag every TM server sets. Keep the dkN indices
  ## contiguous from 0 — Finder stops reading at the first gap.
  ############################################################################

  services.avahi = {
    enable = true;
    # `publish.*` is off by default in nixpkgs (ticket 05 flagged exactly this).
    publish = {
      enable = true;
      userServices = true;
      addresses = true;
      workstation = true;
    };
    # Resolve .local from this host too; Ubuntu has nss-mdns installed.
    nssmdns4 = true;

    extraServiceFiles.timemachine = ''
      <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
      <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
      <service-group>
        <name replace-wildcards="yes">%h</name>
        <service>
          <type>_smb._tcp</type>
          <port>445</port>
        </service>
        <service>
          <type>_device-info._tcp</type>
          <port>0</port>
          <txt-record>model=MacSamba</txt-record>
        </service>
        <service>
          <type>_adisk._tcp</type>
          <port>9</port>
          <txt-record>sys=waMa=0,adVF=0x100</txt-record>
          <txt-record>dk0=adVN=timemachine_myers,adVF=0x82</txt-record>
          <txt-record>dk1=adVN=timemachine_laura,adVF=0x82</txt-record>
          <txt-record>dk2=adVN=timemachine_lillian,adVF=0x82</txt-record>
          <txt-record>dk3=adVN=timemachine_arthur,adVF=0x82</txt-record>
        </service>
      </service-group>
    '';
  };

  ############################################################################
  ## Still owed by Window A / Window B, not by this file
  ##
  ## TODO(window A): /var/lib/samba must be populated from Ubuntu's copy
  ##   (611 KiB per ticket 07's census) BEFORE the first NixOS smbd start.
  ##   passdb.tdb carries the five accounts and secrets.tdb carries the machine
  ##   SID S-1-5-21-2714372705-3317959847-3259532047. Starting smbd against an
  ##   empty database authenticates nobody and can cost a full 5.87 TiB
  ##   re-backup (ticket 05 finding 6).
  ## TODO(window B): snapshot rpool/srv/samba immediately before the first
  ##   NixOS smbd start — 07-nixpkgs-state-dirs-research.md §4 wants the
  ##   one-command rollback.
  ## TODO(window B): if smbd logs messaging errors after the switch, delete
  ##   /var/lib/samba/msg.lock (or the msg.sock directory) with smbd stopped;
  ##   research §"UNVERIFIED" could not confirm cross-OS cleanup.
  ############################################################################
}
