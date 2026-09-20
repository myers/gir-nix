# gir: sshd and fail2ban (ticket 24, module 3).
#
# This module implements ticket 14's decision and does not re-decide it:
# **exact Ubuntu parity, password authentication included.** gir is
# internet-facing — misfit forwards WAN 2223 -> gir:22 — so every delta here is
# a delta in the attack surface of a reachable host, and every delta in the
# other direction is a lockout risk during a 36-hour cutover.
#
# Primary source: `logs/port-configs-20260919-191439/ssh/` collected on
# 2026-09-19 — `sshd_config`, the full `sshd -T` effective config,
# `jail.local`, `jail.d/defaults-debian.conf` and `fail2ban-client status`.
# Checked against nixpkgs `c3eea5b` (the flake pin), NOT against the manual:
# several of the "NixOS default" claims in circulation are wrong for this pin.
#
# Deliberately NOT here:
#   * `services.openssh.hostKeys` — users.nix owns it, pointing at
#     /etc/gir-secrets/ssh. `hostKeys` is a `listOf attrs`, so a second
#     definition would CONCATENATE, not replace, and sshd would be handed six
#     host-key entries. See the note at its definition site in users.nix.
#   * any `users.*` — users.nix owns the accounts (ticket 11).
#   * any firewall port — `networking.firewall.enable = false` (ticket 14), so
#     there is nothing to open. `openFirewall` is turned off below to say so.
{
  config,
  lib,
  ...
}:

{
  ##############################################################################
  # 1. sshd
  #
  # Settings appear below ONLY where nixpkgs' default differs from Ubuntu's
  # effective config, plus the two security-load-bearing ones that already match
  # and are restated because an upstream default flip would be silent.
  #
  # Verified to match already, so not restated (nixpkgs default == `sshd -T`):
  #   Port 22                       ports = [ 22 ]
  #   ListenAddress (wildcard)      listenAddresses = [] -> 0.0.0.0:22 + [::]:22
  #   UsePAM yes                    settings.UsePAM = true
  #   UseDNS no                     settings.UseDns = false
  #   StrictModes yes               settings.StrictModes = true
  #   PrintMotd no                  settings.PrintMotd = false (pam_motd does it)
  #   AuthorizedPrincipalsFile none settings.AuthorizedPrincipalsFile = "none"
  #   Banner none                   settings.Banner = null
  #   AllowUsers / AllowGroups / DenyUsers / DenyGroups: Ubuntu sets NONE of
  #     them (`sshd -T` prints no allowusers/allowgroups line), and nixpkgs'
  #     defaults are all null. Nothing to write.
  #   LoginGraceTime 120, MaxAuthTries 6, MaxSessions 10, MaxStartups
  #     10:30:100, ClientAliveInterval 0, ClientAliveCountMax 3, TCPKeepAlive
  #     yes, Compression (delayed), PermitTunnel no, AllowTcpForwarding yes,
  #     AllowAgentForwarding yes, PermitTTY yes, PermitUserEnvironment no,
  #     IPQoS lowdelay throughput, AuthenticationMethods any, RekeyLimit default:
  #     Ubuntu leaves every one of these at the OpenSSH upstream default
  #     (commented out in sshd_config) and nixpkgs does not set them either, so
  #     both sides inherit the same value from OpenSSH. Restating them would
  #     only create a second place to drift.
  ##############################################################################

  services.openssh = {
    enable = true;

    # Ticket 14: the firewall is off, so this is already a no-op — set anyway so
    # that turning the firewall on later is a deliberate, visible decision and
    # not something this module does behind the post-soak hardening ticket's
    # back. (`networking.firewall.allowedTCPPorts` is the only thing it feeds.)
    openFirewall = false;

    # DIFFERS. nixpkgs curates a narrow, modern Ciphers/Macs/KexAlgorithms set
    # (`enableRecommendedAlgorithms = true` by default): 6 ciphers, 3 MACs,
    # 6 KEX. Ubuntu pins NOTHING — `sshd_config` has no Ciphers/MACs/KexAlgorithms
    # line, so `sshd -T` shows OpenSSH's own defaults: 11 MACs including
    # hmac-sha1 and umac-64, and 9 KEX including the ecdh-sha2-nistp* set and
    # diffie-hellman-group14-sha256.
    #
    # Turning the curation off makes sshd emit no algorithm lines at all, so it
    # falls back to the upstream defaults of its own OpenSSH — which is exactly
    # the shape Ubuntu is in. That is the closest achievable parity: pinning
    # Ubuntu's literal strings instead would be worse, because nixpkgs ships
    # OpenSSH 10.5p1 against Ubuntu's 8.9 and any name 10.5 has retired would
    # fail the module's own `sshd -G -T` build-time config check.
    #
    # Residual, accepted delta: 10.5's upstream defaults are not byte-identical
    # to 8.9's (10.5 adds the mlkem768x25519-sha256 / sntrup761 PQ KEX and has
    # retired some legacy host-key algorithms). Both are supersets of what the
    # clients that reach this host actually negotiate. Narrowing the set is a
    # post-soak hardening item, per ticket 14, not a cutover change.
    enableRecommendedAlgorithms = false;

    settings = {
      # DIFFERS, and this is the hazard. Ubuntu: `passwordauthentication yes`
      # (the directive is commented out in sshd_config, and OpenSSH's default is
      # yes). Ticket 14: password logins as `myers` really happen — 24 from the
      # LAN and 2 from 174.219.x.x in the last 90 days — so keys-only would lock
      # a real user out mid-cutover. Moving to keys-only is explicitly a
      # post-soak hardening item.
      #
      # nixpkgs `c3eea5b` happens to default this to `true` as well, so this
      # line changes nothing today. It is written out anyway because it is the
      # single most consequential setting on an internet-facing host: if a later
      # nixpkgs bump flips the default (it is a recurring upstream proposal),
      # the flip must show up as a diff against THIS line, not as a silent
      # lockout on the next `nixos-rebuild`.
      PasswordAuthentication = true;

      # DIFFERS. Ubuntu's sshd_config sets `KbdInteractiveAuthentication no`
      # explicitly; nixpkgs defaults it to `true`. Left at the nixpkgs default
      # this would open a second, PAM-driven password path that Ubuntu does not
      # have — on a host where fail2ban's counters are tuned to the one path
      # that exists today.
      KbdInteractiveAuthentication = false;

      # Matches the nixpkgs default; restated for the same reason as
      # PasswordAuthentication. `sshd -T` prints `permitrootlogin
      # without-password`, which is the deprecated spelling of the identical
      # `prohibit-password` — Ubuntu leaves the directive commented out, so both
      # sides are on OpenSSH's default. With PasswordAuthentication on, this is
      # what keeps root out over the WAN.
      PermitRootLogin = "prohibit-password";

      # DIFFERS. Ubuntu sets `GatewayPorts yes`; nixpkgs defaults to "no".
      # Load-bearing: it is what lets a client's `ssh -R` bind a non-loopback
      # address on gir. Note this is the one Ubuntu setting that widens exposure
      # rather than narrowing it — ticket 14 keeps it at parity regardless, and
      # it is a candidate for the post-soak hardening ticket.
      GatewayPorts = "yes";

      # DIFFERS. Ubuntu sets `X11Forwarding yes`; nixpkgs defaults to false.
      # Enabling it makes `programs.ssh.setXAuthLocation` default to true, which
      # emits `XAuthLocation <store>/bin/xauth` and pulls pkgs.xauth into the
      # system closure — the NixOS equivalent of Ubuntu's `xauthlocation
      # /usr/bin/xauth`. Without that, sshd.nix's own assertion ("cannot enable
      # X11 forwarding without setting xauth location") fails the build.
      X11Forwarding = true;

      # DIFFERS. Ubuntu sets `AcceptEnv LANG LC_*`; nixpkgs leaves AcceptEnv
      # null, so nothing is emitted and OpenSSH's default (accept nothing)
      # applies. Dropping it would silently change the locale every incoming
      # session lands in, which is how "it works on Ubuntu" shell breakage
      # starts.
      AcceptEnv = [
        "LANG"
        "LC_*"
      ];

      # DIFFERS *because of fail2ban*, not because of sshd. Enabling
      # services.fail2ban makes the fail2ban module set
      # `services.openssh.settings.LogLevel = lib.mkDefault "VERBOSE"`. Ubuntu
      # is at `loglevel INFO` and its sshd jail bans successfully at INFO — the
      # last bans landed 2026-09-12 — because the sshd filter matches the
      # "Failed password"/"Invalid user" lines, which are INFO. Overriding the
      # mkDefault back to INFO keeps both auth.log volume and the journal's
      # contents at parity; VERBOSE additionally logs every offered key
      # fingerprint, which is a privacy change nobody asked for.
      LogLevel = "INFO";
    };

    # Subsystem: NOT at literal parity, and cannot be. Ubuntu's sshd_config says
    # `Subsystem sftp /usr/lib/openssh/sftp-server`; that path does not exist on
    # NixOS. `allowSFTP` (default true) emits
    # `Subsystem sftp <openssh>/libexec/sftp-server` with no extra flags, which
    # is the same binary from the same project at the store path. `sftpFlags`
    # stays empty, matching Ubuntu's flagless Subsystem line. Nothing to set.
    #
    # AuthorizedKeysFile: also not at literal parity. Ubuntu has the OpenSSH
    # default `.ssh/authorized_keys .ssh/authorized_keys2`; NixOS emits
    # `%h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`. The first entry is
    # the same file. The difference is that NixOS drops `authorized_keys2` and
    # adds the module's own key directory (empty here — users.nix declares no
    # `openssh.authorizedKeys.keys`). Left at the default deliberately: the
    # nixpkgs list is built by `++` in the module's own config section, so the
    # only way to remove `/etc/ssh/authorized_keys.d/%u` is a `mkForce` that
    # would break every other module that wants to add a key.
    # TODO(ticket 24): before Window B, confirm no account under /home has a
    # `~/.ssh/authorized_keys2` — `authorized_keys2` has been deprecated
    # upstream for years, but gir's homes are carried over from Ubuntu
    # unchanged (ticket 11) and nothing has audited them for one.
    #
    # AddressFamily: nixpkgs derives it, emitting `AddressFamily any` when
    # `networking.enableIPv6` is true (the default) and `inet` when it is false.
    # Ubuntu is at `any`. Ticket 14 disables IPv6 with
    # `net.ipv6.conf.*.disable_ipv6 = 1` sysctls rather than with the NixOS
    # option, so this lands on `any` and matches — but it is networking.nix that
    # decides, not this file.
    # TODO(ticket 24): when networking.nix lands, check it does not also set
    # `networking.enableIPv6 = false`. If it does, sshd drops to
    # `AddressFamily inet` (harmless: the [::] bind fails today anyway) and the
    # fail2ban ignoreip below silently loses its `::1` entry (also harmless, and
    # compensated for explicitly in section 2).
  };

  ##############################################################################
  # 2. fail2ban
  #
  # Ubuntu's configuration is small and entirely visible in the collected files:
  #   jail.d/defaults-debian.conf   [sshd] enabled = true          <- the only jail
  #   jail.local (from ansible)     [DEFAULT] ignoreip = 127.0.0.1/8 ::1 192.168.42.0/24
  #   everything else               Debian's stock jail.conf
  # and `fail2ban-client status` confirms it at runtime: "Number of jail: 1,
  # Jail list: sshd".
  #
  # So the parity target is Debian's jail.conf defaults, not nixpkgs'. Those two
  # disagree, which is the whole reason this section exists.
  ##############################################################################

  services.fail2ban = {
    enable = true;

    # DIFFERS. nixpkgs defaults `maxretry` to 3; Debian's jail.conf uses 5, and
    # ticket 14 records 5 as the value to carry over. Three strikes on a host
    # that still takes passwords from the LAN is a good way to ban a family
    # member's laptop — the exact failure jail.local's ignoreip was written to
    # prevent.
    maxretry = 5;

    # Matches, so not restated:
    #   bantime         nixpkgs default "10m" == Debian's jail.conf 10m
    #   banaction       nixpkgs picks "iptables-multiport" whenever
    #                   `networking.nftables.enable` is false, which ticket 14
    #                   keeps off; Debian's jail.conf default is the same string
    #   bantime-increment.enable
    #                   nixpkgs default false == Ubuntu (jail.conf ships
    #                   bantime.increment commented out); ticket 14: "no bantime
    #                   increment"
    #   packageFirewall nixpkgs uses `networking.firewall.package`, which is
    #                   `pkgs.iptables` — the iptables-nft shim, the same
    #                   `iptables v1.8.7 (nf_tables)` Ubuntu runs (ticket 14).
    #                   The option is defined even with the firewall disabled.

    # Ubuntu's literal string is "127.0.0.1/8 ::1 192.168.42.0/24". nixpkgs
    # builds the rendered value as
    #   "127.0.0.1/8 " + (if networking.enableIPv6 then "::1 " else "") + ignoreIP
    # so `::1` is contributed by the module only when IPv6 is enabled. The
    # conditional below restores it in the other case, making the rendered
    # ignoreip byte-identical to Ubuntu's either way instead of depending on
    # what networking.nix decides.
    #
    # The LAN /24 is the point of the file: jail.conf ships ignoreip commented
    # out, so without it any host on 192.168.42.0/24 can lock itself out of gir
    # after a handful of bad auths. Ticket 14: the pod, libvirt and 192.168.69.0/24
    # ranges are deliberately NOT added.
    ignoreIP = lib.optional (!config.networking.enableIPv6) "::1" ++ [
      "192.168.42.0/24"
    ];

    jails = {
      DEFAULT.settings = {
        # Restated rather than inherited. `findtime` is not a nixpkgs option, so
        # its value comes from whichever jail.conf the fail2ban package happens
        # to ship — a file this repo does not pin and does not see in review.
        # Debian's is 10m and ticket 14's parity target is 10m; writing it here
        # makes `fail2ban-client get sshd findtime` an auditable check instead
        # of a property of an upstream tarball.
        findtime = "10m";
      };

      # The one jail, matching jail.d/defaults-debian.conf and the live
      # `fail2ban-client status`. nixpkgs' module already creates an `sshd` jail
      # whenever `services.openssh.enable` is true (it defines
      # `jails.sshd.settings.port` from `services.openssh.ports`, and `enabled`
      # defaults to true) — stated here so the jail list is legible in this file
      # rather than implied by another module's mkIf.
      #
      # No other jail is defined, deliberately: Ubuntu runs exactly one.
      sshd.enabled = true;
    };
  };

  # Two accepted, unavoidable deltas from Ubuntu, both consequences of NixOS
  # itself rather than choices made here:
  #
  # 1. backend = systemd. nixpkgs pins `backend = "systemd"` in the DEFAULT
  #    jail. Ubuntu's jail.conf default is `auto`, which on gir resolves to
  #    reading /var/log/auth.log via rsyslog. NixOS has no /var/log/auth.log —
  #    journald is the only sink — so `systemd` is the only backend that can
  #    see a failed login at all. Keeping Ubuntu's `auto` would produce a jail
  #    that starts, reports "active", and never bans anything.
  #    Consequence for ticket 14's test 5: `fail2ban-client get sshd backend`
  #    will read `systemd`, not `auto`. That is expected; the ban behaviour, not
  #    the backend string, is what the test should confirm.
  #
  # 2. The eval warning "fail2ban can not be used without a firewall". nixpkgs
  #    emits it whenever both `networking.firewall.enable` and
  #    `networking.nftables.enable` are false, which is ticket 14's deliberate
  #    configuration. It is a warning, not an assertion: the build succeeds and
  #    bans still land, because banaction `iptables-multiport` shells out to the
  #    iptables-nft binary and inserts the f2b-sshd chain itself, exactly as it
  #    does on Ubuntu (where ufw is likewise inactive). Ticket 14 records this
  #    as expected and harmless; it is NOT suppressed here, because silencing it
  #    would also silence the day someone turns the firewall on.

  ##############################################################################
  # 3. Fail-closed wiring for the host keys
  #
  # The host keys live on `rpool/srv/secrets` -> /etc/gir-secrets/ssh (ticket 07
  # item 12), so that every client's known_hosts entry survives the cutover.
  # storage.nix mounts it `neededForBoot`.
  #
  # This is not belt-and-braces. `sshd-keygen.service`'s only guard is
  # `ConditionFileNotEmpty=|!<path>` per key — "run if any key is missing or
  # empty". If the secrets dataset ever fails to mount, all three paths are
  # missing, the condition passes, and the unit cheerfully GENERATES THREE NEW
  # HOST KEYS into the empty mountpoint directory on /. gir then answers with
  # unknown keys, every client on the LAN gets a
  # REMOTE HOST IDENTIFICATION HAS CHANGED banner, and the real keys are still
  # sitting unmounted on the pool. `RequiresMountsFor=` turns that into a clean
  # failure to start, which is the repo's rule (storage.nix section 4a).
  #
  # Declared here rather than in storage.nix because it is ssh's invariant;
  # `unitConfig` list values concatenate, so this coexists with anything
  # storage.nix adds for the same units.
  ##############################################################################

  systemd.services.sshd-keygen.unitConfig.RequiresMountsFor = [ "/etc/gir-secrets" ];
  systemd.services.sshd.unitConfig.RequiresMountsFor = [ "/etc/gir-secrets" ];
}
