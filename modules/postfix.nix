{ pkgs, ... }:
{
  ############################################################################
  ## Postfix -- how root's mail reaches a person
  ##
  ## Ubuntu relayed everything through Gmail: Postfix with `relayhost =
  ## [smtp.gmail.com]:587`, SASL from `/etc/postfix/sasl_passwd` (an app
  ## password), TLS required, and `root: myers@maski.org` in /etc/aliases. The
  ## alias is younger than it looks -- ticket 05 added it on 2026-09-16 after
  ## finding that cron, mdadm, the scrub jobs and ZED had all been dead-ending
  ## in /var/mail/root for years, and only smartd got through because it names
  ## the address itself.
  ##
  ## Ticket 05 said "keep Postfix natively, and fix the root alias". Window A
  ## copied the credential to /etc/gir-secrets/postfix-sasl_passwd. Ticket 24
  ## then ported every other kept service and never mentioned Postfix, so NixOS
  ## ran from the 2026-09-20 cutover with no MTA at all: no sendmail wrapper,
  ## and ZED's scrub-finish notification failed on 2026-09-21 with `mail
  ## exit=1`. Every consumer was wired up and waiting -- smartd's mailer is
  ## /run/wrappers/bin/sendmail (monitoring.nix), ZED and the NUT helper call
  ## mailutils' `mail`, whose sendmail is nixpkgs' system-sendmail shim that
  ## execs /run/wrappers/bin/sendmail -- and with Prometheus dropped for the
  ## migration this IS the alerting path. Ticket 26 records the gap.
  ##
  ## Settings are Ubuntu's `postconf -n` (logs/port-configs-20260919-192156/
  ## misc/main.cf) minus Debian-isms, with two deliberate differences:
  ##
  ##   * `smtp_sasl_password_maps` is `texthash:`, not `hash:`. The module's
  ##     `mapFiles` would symlink the secret into /var/lib/postfix/conf (0755)
  ##     and `postmap` it there. texthash reads the plain file at open time, and
  ##     Postfix opens SASL password maps in the smtp client's pre-jail init,
  ##     as root, before it drops to `postfix` -- which is why SASL_README says
  ##     to keep the file root 0600 and it works. So the secret never leaves the
  ##     0700 secrets dataset and nothing is postmapped. The file is the same
  ##     one-line `[smtp.gmail.com]:587 user:password` that postmap read.
  ##   * No smtpd TLS. Ubuntu served the snakeoil cert on port 25; nothing
  ##     connects inbound with TLS (mynetworks is loopback only, no host or
  ##     pod names gir as an SMTP server), and NixOS has no snakeoil pair.
  ##
  ## `myorigin` was `/etc/mailname`, never captured. Debian's installer writes
  ## `mydestination = $mailname, $myhostname, localhost.$domain, localhost`,
  ## and Ubuntu's list starts `gir.maski.org, gir.motherbrain.local`, so the
  ## mail name was gir.maski.org. Gmail rewrites the envelope sender to the
  ## account anyway; this only shapes the From: header.
  ############################################################################
  services.postfix = {
    enable = true;
    # The alias ticket 05 added. postmasterAlias defaults to root.
    rootAlias = "myers@maski.org";

    settings.main = {
      myhostname = "gir.motherbrain.local";
      myorigin = "gir.maski.org";
      mydestination = [
        "gir.maski.org"
        "gir.motherbrain.local"
        "localhost.motherbrain.local"
        "localhost"
      ];
      mynetworks = [
        "127.0.0.0/8"
        "[::ffff:127.0.0.0]/104"
        "[::1]/128"
      ];
      # Parity: Ubuntu listened on every interface. The firewall is off (ticket
      # 14) and port 25 is not forwarded from the WAN, so this is LAN-visible
      # exactly as before. Relay is refused outside mynetworks.
      inet_interfaces = "all";
      inet_protocols = "ipv4";
      append_dot_mydomain = false;
      biff = false;
      mailbox_size_limit = 0;
      recipient_delimiter = "+";

      # The relay.
      relayhost = [ "[smtp.gmail.com]:587" ];
      smtp_sasl_auth_enable = true;
      smtp_sasl_security_options = [ "noanonymous" ];
      smtp_sasl_password_maps = [ "texthash:/etc/gir-secrets/postfix-sasl_passwd" ];
      smtp_tls_security_level = "encrypt";
      smtp_tls_CAfile = "/etc/ssl/certs/ca-certificates.crt";
      smtp_tls_session_cache_database = "btree:\${data_directory}/smtp_scache";
    };
  };

  # `mail root` is how every runbook and comment in this repo sends a message,
  # and Ubuntu had it on PATH (mailutils). ZED and nut.nix reach mailutils by
  # store path and do not need this; the first switch (2026-09-22) proved that
  # a human at a root shell does: `mail: command not found`.
  environment.systemPackages = [ pkgs.mailutils ];

  # Same rule as sshd (ssh.nix): if the secrets dataset is not mounted, fail to
  # start rather than run without the credential. Without this Postfix would
  # start, accept root's mail, and bounce it on the first delivery attempt
  # with a SASL error -- which is exactly the mail nobody would see.
  systemd.services.postfix.unitConfig.RequiresMountsFor = [ "/etc/gir-secrets" ];
}
